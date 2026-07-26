# frozen_string_literal: true

# Shared helpers for tebako-packages feedstock tools (spec 13 §9).
# Conventions: tebako-packages/index docs/conventions.md.

require "yaml"
require "json"
require "fileutils"
require "digest"
require "shellwords"
require "open3"

module Tpkg
  ROOT = File.expand_path("../..", __dir__).freeze

  # platform triplet (recipe) => CI runner + vcpkg overlay triplet
  PLATFORM_MAP = {
    "x86_64-linux-gnu"  => { "runner" => "ubuntu-24.04",     "vcpkg_triplet" => "x64-linux-dynamic" },
    "aarch64-linux-gnu" => { "runner" => "ubuntu-24.04-arm", "vcpkg_triplet" => "arm64-linux-dynamic" },
    "aarch64-macos"     => { "runner" => "macos-14",         "vcpkg_triplet" => "arm64-osx-dynamic" },
    "x86_64-macos"      => { "runner" => "macos-13",         "vcpkg_triplet" => "x64-osx-dynamic" }
  }.freeze

  # The glibc family + the program loader stay OUTSIDE the closure: they must
  # match the host kernel/loader (the preload shim provides them). Everything
  # else ldd resolves — including libstdc++/libgcc_s — is packaged.
  CLOSURE_EXCLUDE = %w[
    linux-vdso.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 ld-musl-x86_64.so.1
    libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1
    libresolv.so.2 libutil.so.1 libanl.so.1 libnsl.so.1
  ].freeze
  CLOSURE_EXCLUDE_RE = /\Alibnss_|\Alinux-gate/ .freeze

  module_function

  def recipe(path)
    YAML.load_file(path)
  end

  def log(msg)  = $stdout.puts("[tpkg] #{msg}")
  def warn(msg) = $stderr.puts("[tpkg] WARNING: #{msg}")

  def die(msg)
    $stderr.puts("[tpkg] ERROR: #{msg}")
    exit 1
  end

  def sh(*cmd, chdir: nil, env: {}, quiet: false)
    log("$ #{cmd.join(' ')}#{"   (cd #{chdir})" if chdir}") unless quiet
    kw = {}
    kw[:chdir] = chdir if chdir
    system(env, *cmd, **kw) or die("command failed (#{$?.exitstatus}): #{cmd.join(' ')}")
  end

  def capture(*cmd, env: {}, chdir: nil)
    kw = {}
    kw[:chdir] = chdir if chdir
    out, status = Open3.capture2e(env, *cmd, **kw)
    [out, status.success?]
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  # Fetch url to dest, verifying sha256. One re-download attempt on mismatch;
  # aborts otherwise. Every download in the feedstock goes through here.
  def fetch(url, dest, sha256)
    FileUtils.mkdir_p(File.dirname(dest))
    2.times do |attempt|
      if File.exist?(dest)
        actual = sha256(dest)
        if actual == sha256
          log("cache hit #{File.basename(dest)} sha256=#{actual[0, 16]}…")
          return dest
        end
        warn("cached #{dest} has sha256=#{actual}, expected #{sha256} — refetching")
        FileUtils.rm_f(dest)
      end
      log("fetch #{url}")
      sh("curl", "-fsSL", "--retry", "3", "--no-progress-meter", "-o", dest, url)
      actual = sha256(dest)
      return dest if actual == sha256

      warn("sha256 mismatch after download (attempt #{attempt + 1}): got #{actual}, want #{sha256}")
    end
    die("could not fetch #{url} with expected sha256 #{sha256}")
  end

  # Clone a git repo at a pinned commit and verify HEAD matches the pin.
  # A commit pin authenticates the whole tree; used where upstream ships no
  # release tarball to sha256 (vcpkg, dwarfs-t).
  def git_pinned(git_url, commit, dest)
    if !File.directory?(File.join(dest, ".git"))
      sh("git", "clone", "--filter=blob:none", git_url, dest)
    end
    unless system("git", "-C", dest, "cat-file", "-e", "#{commit}^{commit}")
      sh("git", "fetch", "--quiet", "origin", commit, chdir: dest)
    end
    sh("git", "checkout", "--quiet", commit, chdir: dest)
    head, = capture("git", "rev-parse", "HEAD", chdir: dest)
    # normalize: a pin may name an annotated tag object; compare commits
    want, = capture("git", "rev-parse", "#{commit}^{commit}", chdir: dest)
    die("pin mismatch in #{dest}: HEAD=#{head.strip}, want #{want.strip}") unless head.strip == want.strip
    dest
  end

  def cache_dir
    dir = ENV.fetch("TPKG_CACHE", File.join(ROOT, ".cache"))
    FileUtils.mkdir_p(dir)
    dir
  end

  # Locate or build mkdwarfs/dwarfs from tamatebako/dwarfs-t.
  # Order: $MKDWARFS env → tool cache → pinned source build.
  # (No published dwarfs-t releases exist to download yet — see build-notes.)
  def ensure_dwarfs_tools(recipe)
    if ENV["MKDWARFS"] && File.executable?(ENV["MKDWARFS"])
      log("using $MKDWARFS=#{ENV['MKDWARFS']}")
      return { "mkdwarfs" => ENV["MKDWARFS"],
               "dwarfs" => ENV["DWARFS"],
               "dwarfsextract" => ENV["DWARFSEXTRACT"] }.compact
    end

    pin = recipe.fetch("image").fetch("dwarfs_t")
    dest = File.join(cache_dir, "dwarfs-t", pin["commit"])
    bindir = File.join(dest, "bin")
    mkdwarfs = File.join(bindir, "mkdwarfs")
    unless File.executable?(mkdwarfs)
      # dwarfs-t manpage codegen needs python mistletoe; ubuntu-24.04's
      # PEP 668 blocks plain `pip3 install` (externally-managed-environment)
      have_mistletoe = -> { system("python3", "-c", "import mistletoe", %i[out err] => File::NULL) }
      unless have_mistletoe.call
        sudo = Process.uid.zero? ? [] : ["sudo"]
        system(*sudo, "apt-get", "install", "-y", "-qq", "python3-mistletoe") if system("command -v apt-get >/dev/null 2>&1")
        unless have_mistletoe.call
          system("pip3", "install", "--break-system-packages", "mistletoe") ||
            system("pip3", "install", "--user", "mistletoe") ||
            die("could not install python mistletoe (dwarfs-t manpage codegen needs it)")
        end
      end
      log("building mkdwarfs-t from pinned source #{pin['commit'][0, 12]}… (no published releases)")
      src = git_pinned(pin["git"], pin["commit"], File.join(dest, "src"))
      triplet = ENV.fetch("TPKG_DWARFS_TRIPLET", "x64-linux")
      build = File.join(dest, "build")
      sh("cmake", "-S", src, "-B", build, "-G", "Ninja",
         "-DCMAKE_BUILD_TYPE=Release",
         "-DCMAKE_TOOLCHAIN_FILE=#{File.join(vcpkg_root_for(recipe), 'scripts/buildsystems/vcpkg.cmake')}",
         "-DVCPKG_TARGET_TRIPLET=#{triplet}",
         "-DVCPKG_MANIFEST_FEATURES=",
         "-DVCPKG_OVERLAY_PORTS=#{File.join(src, 'vcpkg_ports')}",
         "-DWITH_TOOLS=ON", "-DWITH_LIBDWARFS=ON", "-DWITH_TESTS=OFF", "-DWITH_BENCHMARKS=OFF")
      sh("cmake", "--build", build, "--parallel", "4", "--target", "mkdwarfs", "dwarfs", "dwarfsextract")
      FileUtils.mkdir_p(bindir)
      %w[mkdwarfs dwarfs dwarfsextract].each do |t|
        found = Dir[File.join(build, "**", t)].find { |f| File.executable?(f) && !File.directory?(f) }
        die("built #{t} not found under #{build}") unless found
        FileUtils.cp(found, bindir)
      end
    end
    { "mkdwarfs" => File.join(bindir, "mkdwarfs"),
      "dwarfs" => File.join(bindir, "dwarfs"),
      "dwarfsextract" => File.join(bindir, "dwarfsextract") }
  end

  # vcpkg checkout used for the inkscape deps. dwarfs-t's own manifest pins a
  # different baseline; its build resolves that itself through this root when
  # TPKG_DWARFS_VCPKG is unset. Kept simple: one vcpkg checkout per recipe.
  def vcpkg_root_for(recipe)
    spec = recipe.dig("build", "vcpkg") or die("recipe has no build.vcpkg section")
    git_pinned(spec["git"], spec["commit"], File.join(cache_dir, "vcpkg"))
  end

  # Parse `ldd` output into {soname => resolved_path}.
  def ldd_resolve(file, libdirs)
    env = { "LD_LIBRARY_PATH" => libdirs.join(":") }
    out, ok = capture("ldd", file, env: env)
    die("ldd failed on #{file}:\n#{out}") unless ok
    resolved = {}
    out.each_line do |line|
      if line =~ /^\s*(\S+)\s+=>\s+(\/\S+)\s+\(0x[0-9a-f]+\)/ ||
         line =~ /^\s*(\/\S+)\s+\(0x[0-9a-f]+\)/
        name = Regexp.last_match(2) ? Regexp.last_match(1) : File.basename(Regexp.last_match(1))
        path = Regexp.last_match(2) || Regexp.last_match(1)
        resolved[name] = path
      elsif line =~ /(\S+)\s+=>\s+not found/
        resolved[Regexp.last_match(1)] = nil
      end
    end
    resolved
  end

  def elf?(path)
    File.file?(path) && !File.symlink?(path) &&
      File.open(path, "rb") { |f| f.read(4) } == "\x7fELF"
  rescue Errno::EACCES, Errno::ENOENT
    false
  end

  def excluded_lib?(name)
    CLOSURE_EXCLUDE.include?(name) || name.match?(CLOSURE_EXCLUDE_RE)
  end
end
