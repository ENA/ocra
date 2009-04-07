#!/usr/bin/env ruby
# -*- ruby -*-

module Ocra
  Signature = [0x41, 0xb6, 0xba, 0x4e]
  OP_END = 0
  OP_CREATE_DIRECTORY = 1
  OP_CREATE_FILE = 2
  OP_CREATE_PROCESS = 3
  OP_DECOMPRESS_LZMA = 4
  OP_SETENV = 5

  class << self
    attr_accessor :lzma_mode
    attr_accessor :extra_dlls
    attr_accessor :files
    attr_accessor :load_autoload
    attr_accessor :force_windows
    attr_accessor :force_console
    attr_accessor :quiet
    attr_reader :lzmapath
    attr_reader :stubimage
    
    def get_next_embedded_image
      DATA.read(DATA.readline.to_i).unpack("m")[0]
    end
  end

  def Ocra.initialize_ocra
    @lzma_mode = true
    @extra_dlls = []
    @files = []
    @load_autoload = true
    
    if defined?(DATA)
      @stubimage = get_next_embedded_image
      lzmaimage = get_next_embedded_image
      @lzmapath = File.join(ENV['TEMP'], 'lzma.exe').tr('/','\\')
      File.open(@lzmapath, "wb") { |file| file << lzmaimage }
    else
      ocrapath = File.dirname(__FILE__)
      @stubimage = File.open(File.join(ocrapath, '../share/ocra/stub.exe'), "rb") { |file| file.read }
      @lzmapath = File.expand_path('../share/ocra/lzma.exe', ocrapath).tr('/','\\')
      raise "lzma.exe not found" unless File.exist?(@lzmapath)
    end
  end

  def Ocra.parseargs(argv)
    usage = <<EOF
ocra [--dll dllname] [--no-lzma] script.rb

--dll dllname    Include additional DLLs from the Ruby bindir.
--no-lzma        Disable LZMA compression of the executable.
--quiet          Suppress output.
--help           Display this information.
--windows        Force Windows application (rubyw.exe)
--console        Force console application (ruby.exe)
--no-autoload    Don't load/include script.rb's autoloads
EOF

    while arg = argv.shift
      case arg
      when /\A--(no-)?lzma\z/
        Ocra.lzma_mode = !$1
      when /\A--dll\z/
        Ocra.extra_dlls << argv.shift
      when /\A--quiet\z/
        Ocra.quiet = true
      when /\A--windows\z/
        Ocra.force_windows = true
      when /\A--console\z/
        Ocra.force_console = true
      when /\A--no-autoload\z/
        Ocra.load_autoload = false
      when /\A--help\z/, /\A--/
        puts usage
        exit
      else
        @files << arg
      end
    end

    if Ocra.files.empty?
      puts usage
      exit
    end
  end

  # Force loading autoloaded constants. Searches through all modules
  # (and hence classes), and checks their constants for autoloaded
  # ones, then attempts to load them.
  def Ocra.attempt_load_autoload
    modules_checked = []
    loop do
      modules_to_check = []
      ObjectSpace.each_object(Module) do |mod|
        modules_to_check << mod unless modules_checked.include?(mod)
      end
      break if modules_to_check.empty?
      modules_to_check.each do |mod|
        modules_checked << mod
        mod.constants.each do |const|
          if mod.autoload?(const)
            begin
              mod.const_get(const)
            rescue LoadError
              puts "=== WARNING: #{mod}::#{const} was not loadable"
            end
          end
        end
      end
    end
  end
  
  def Ocra.build_exe
    # Attempt to autoload libraries before doing anything else.
    attempt_load_autoload if Ocra.load_autoload

    # Store the currently loaded files (before we require rbconfig for
    # our own use).
    features = $LOADED_FEATURES.dup

    # Find gemspecs to include
    if defined?(Gem)
      gemspecs = Gem.loaded_specs.map { |name,info| info.loaded_from }
    else
      gemspecs = []
    end

    require 'rbconfig'
    exec_prefix = RbConfig::CONFIG['exec_prefix']
    src_prefix = File.expand_path(File.dirname(Ocra.files[0]))
    sitelibdir = RbConfig::CONFIG['sitelibdir']
    bindir = RbConfig::CONFIG['bindir']
    libruby_so = RbConfig::CONFIG['LIBRUBY_SO']

    instsitelibdir = sitelibdir[exec_prefix.size+1..-1]
    
    # Find loaded files
    libs = []
    features.each do |filename|
      path = $:.find { |path| File.exist?(File.expand_path(filename, path)) }
      if path
        fullpath = File.expand_path(filename, path)
        if fullpath.index(exec_prefix) == 0
          libs << [ fullpath, fullpath[exec_prefix.size+1..-1] ]
        elsif fullpath.index(src_prefix) == 0
          libs << [ fullpath, "src/" + fullpath[src_prefix.size+1..-1]]
        else
          libs << [ fullpath, File.join(instsitelibdir, filename) ]
        end
      else
        puts "=== WARNING: Couldn't find #{filename}"
      end
    end

    executable = Ocra.files[0].sub(/(\.rbw?)?$/, '.exe')

    puts "=== Building #{executable}" unless Ocra.quiet
    SebBuilder.new(executable) do |sb|
      # Add explicitly mentioned files
      Ocra.files.each do |file|
        path = File.join('src', file).tr('/','\\')
        sb.createfile(file, path)
      end

      # Add the ruby executable and DLL
      if (Ocra.files[0] =~ /\.rbw$/ && !Ocra.force_windows) || Ocra.force_console
        rubyexe = "ruby.exe"
      else
        rubyexe = "ruby.exe"
      end
      sb.createfile(File.join(bindir, rubyexe), "bin\\" + rubyexe)
      if libruby_so
        sb.createfile(File.join(bindir, libruby_so), "bin\\#{libruby_so}")
      end

      # Add extra DLLs
      Ocra.extra_dlls.each do |dll|
        sb.createfile(File.join(bindir, dll), File.join("bin", dll).tr('/','\\'))
      end

      # Add gemspecs
      gemspecs.each { |gemspec|
        pref = gemspec[0,exec_prefix.size]
        path = gemspec[exec_prefix.size+1..-1]
        if pref != exec_prefix
          raise "#{gemspec} does not exist in the Ruby installation. Don't know where to put it."
        end
        sb.createfile(gemspec, path.tr('/','\\'))
      }

      # Add loaded libraries
      libs.each do |path, target|
        sb.createfile(path, target.tr('/', '\\'))
      end

      # Set environment variable
      sb.setenv('RUBYOPT', '')
      sb.setenv('RUBYLIB', '')

      # Launch the script
      sb.createprocess("bin\\" + rubyexe, "#{rubyexe} \xff\\src\\" + Ocra.files[0])
      
      puts "=== Compressing" unless Ocra.quiet or not Ocra.lzma_mode
    end
    puts "=== Finished (Final size was #{File.size(executable)})" unless Ocra.quiet
  end
  
  class SebBuilder
    def initialize(path)
      @paths = {}
      File.open(path, "wb") do |ocrafile|
        ocrafile.write(Ocra.stubimage)
        if Ocra.lzma_mode
          @of = ""
        else
          @of = ocrafile
        end
        yield(self)

        if Ocra.lzma_mode
          begin
            File.open("tmpin", "wb") { |tmp| tmp.write(@of) }
            system("#{Ocra.lzmapath} e tmpin tmpout 2>NUL") or fail
            compressed_data = File.open("tmpout", "rb") { |tmp| tmp.read }
            ocrafile.write([OP_DECOMPRESS_LZMA, compressed_data.size, compressed_data].pack("VVA*"))
            ocrafile.write([OP_END].pack("V"))
          ensure
            File.unlink("tmpin") if File.exist?("tmpin")
            File.unlink("tmpout") if File.exist?("tmpout")
          end
        else
          ocrafile.write(@of) if Ocra.lzma_mode
        end

        ocrafile.write([OP_END].pack("V"))
        ocrafile.write([Ocra.stubimage.size].pack("V")) # Pointer to start of opcodes
        ocrafile.write(Signature.pack("C*"))
      end
    end
    def mkdir(path)
      @paths[path] = true
      puts "m #{path}" unless Ocra.quiet
      @of << [OP_CREATE_DIRECTORY, path].pack("VZ*")
    end
    def ensuremkdir(tgt)
      return if tgt == "."
      if not @paths[tgt]
        ensuremkdir(File.dirname(tgt))
        mkdir(tgt)
      end
    end
    def createfile(src, tgt)
      ensuremkdir(File.dirname(tgt))
      str = File.open(src, "rb") { |file| file.read }
      puts "a #{tgt}" unless Ocra.quiet
      @of << [OP_CREATE_FILE, tgt, str.size, str].pack("VZ*VA*")
    end
    def createprocess(image, cmdline)
      puts "l #{image} #{cmdline}" unless Ocra.quiet
      @of << [OP_CREATE_PROCESS, image, cmdline].pack("VZ*Z*")
    end
    def setenv(name, value)
      puts "e #{name} #{value}" unless Ocra.quiet
      @of << [OP_SETENV, name, value].pack("VZ*Z*")
    end
    def close
      @of.close
    end
  end # class SebBuilder
  
end # module Ocra

if File.basename(__FILE__) == File.basename($0)
  Ocra.initialize_ocra
  Ocra.parseargs(ARGV)
  puts "=== Loading script to check dependencies" unless Ocra.quiet
  $0 = "<ocra>"
  ARGV.clear
  at_exit do
    Ocra.build_exe
    exit
  end
  load Ocra.files[0]
end
