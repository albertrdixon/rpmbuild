require 'logger'
require 'find'
require 'pp'
require 'yaml'

class RPMBuild
   def initialize(root, buildroot, opts={})
      raise ArgumentError, "Spec hash must be passed in opts" unless opts.include? :spec
      @root = root
      @buildroot = buildroot

      @conf = opts[:spec]
      @rpmbuild = (opts.include?(:rpmbuild) ? opts[:rpmbuild] : "/usr/bin/rpmbuild")
      logfile = File.open(File.join(@root, "package.log"), 'a')
      @log = Logger.new(logfile)
      @log.formatter = proc do |severity, datetime, progname, msg|
         "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} : [#{severity}] #{msg}\n"
      end
      @log.level = opts[:log_level]
   end

   def build
      @log.debug "spec hash:\n#{@conf.inspect}" if @log.debug?
      @log.info "Preparing rpmbuild directory structure..."
      begin
         prepare
      rescue => e
         @log.fatal e.message
	 @log.fatal e.backtrace.join("\n")
         abort e.message
      end

      @log.info "Writing SPEC files..."
      begin
         write_spec
         write_rpmrc
      rescue => e
         @log.fatal e.message
	 @log.fatal e.backtrace.join("\n")
         abort e.message
      end

      @log.info "Running rpmbuild to create rpm..."
      cmd = []
      begin
        if File.exists? File.join(ENV["HOME"], '.rpmbuild.yml')
          rpmb = Psych.load_file(File.join(ENV["HOME"], '.rpmbuild.yml'))
          cmd.concat rpmb['rpmbuild_options'] if rpmb['rpmbuild_options']
        elsif ENV["RPMBUILD_OPTS"]
          cmd << ENV["RPMBUILD_OPTS"]
        end
        cmd << "--rcfile #{@specdir}/rpmrc"
        cmd << "--target #{@conf[:arch]}"
        cmd << "--define '_rpmdir #{@rpmdir}'"
        cmd << "--buildroot #{@buildroot}"
        cmd << "-bb #{@specdir}/#{@specfile}"
        cmd << ">#{File.join(@root, 'rpmbuild.out')} 2>&1"
      rescue => e
        @log.fatal e.message
        @log.fatal e.backtrace.join("\n")
        abort e.message
      end

      @log.debug("CMD: #{@rpmbuild} #{cmd.join(' ')}") if @log.debug?
      pid = spawn( "#{@rpmbuild} #{cmd.join(' ')}" )
      Process.wait pid

      abort "RPMBUILD FAILED: #{$!}" if $? != 0
      @log.info "Complete"
   end

   private

   def prepare
      @log.debug("Creating dir #{File.join(@root, 'rpm')}") if @log.debug?
      Dir.mkdir(File.join(@root, "rpm"), 0750) unless Dir.exists? File.join(@root, "rpm")
      @log.debug("Creating sub dirs: BUILD, RPMS, SOURCES, SPECS, SRPMS") if @log.debug?
      ["BUILD", "RPMS", "SOURCES", "SPECS", "SRPMS"].each {|d| Dir.mkdir(File.join(@root, "rpm", d), 0750) unless Dir.exists? File.join(@root, "rpm", d)}
      @specdir = File.join(@root, "rpm", "SPECS")
      @rpmdir  = File.join(@root, "rpm", "RPMS")
      self
   end

   def write_spec
      sf = []
      sf << @conf[:tags][:name]
      sf << @conf[:tags][:release]
      @specfile = "#{sf.join('-')}.spec"
      @log.debug("Writing spec file #{@specfile}") if @log.debug?
      File.open(File.join(@specdir, @specfile), 'w', 0640) do |spec|
         if @conf.include? :tags
            [:version, :name].each {|t| raise ArgumentError, "#{t.to_s} must be defined under :tags" unless @conf[:tags].include? t}
            raise ArgumentError, "version is malformed: #{@conf[:tags][:version].inspect}" unless /\A[\w\d_\.]+\.\d+\Z/.match @conf[:tags][:version].to_s
            @conf[:tags].each do |tag, value|
               @log.debug("writing '#{tag}: #{value}'") if @log.debug?
               spec.puts "#{tag}: #{value}"
            end
         end
         if @conf.include? :provides
           @log.debug("writing 'provides: #{@conf[:provides]}'") if @log.debug?
           spec.puts "provides: #{@conf[:provides]}" if @conf.include? :provides
         end
         if @conf.include? :requires
           @log.debug("writing 'requires: #{@conf[:requires].join(', ')}'") if @log.debug?
           spec.puts "requires: " + @conf[:requires].join(", ") if @conf.include? :requires
         end

         spec.puts "%description", (@conf.include?(:description) ? @conf[:description] : "files for the #{@product} software package")
         if @conf.has_key? :scripts
            @log.debug "writing out scripts" if @log.debug?
            @conf[:scripts].each do |script|
               next unless script.has_key? "name"
               case script["name"].downcase.gsub(/[-_]/,'')
               when /\Aprein/
                  spec.puts "%pre"
               when /\Apostin/
                  spec.puts "%post"
               when /\Apreun/
                  spec.puts "%preun"
               when /\Apostun/
                  spec.puts "%postun"
               end
               if script["file"]
                  @log.debug "reading in script file #{File.join(@root, script['file'])}" if @log.debug?
                  @log.debug "will also replace tokens:\n#{@conf[:tokens].inspect}" if @log.debug? and @conf.include? :tokens
                  next unless File.exists?(File.join(@root, script['file']))
                  File.open(File.join(@root, script["file"])) do |file|
                     file.readlines.each do |line|
                        line.gsub! /\A\s*#+.*/, ''
                        next if line.match /\A\s*\Z/
                        if @conf.include? :tokens
                           @conf[:tokens].each do |token, value|
                              line.gsub! /#{token}/, value
                           end
                        end
                        spec.puts line
                     end
                  end
               elsif script["source"]
                  @log.debug "writing script source:\n----\n#{script['source']}\n----" if @log.debug?
                  spec.puts script["source"]
               end
            end
         end

         spec.puts "%docdir #{@conf[:docdir]}" if @conf.include? :docdir
         @log.debug "writing out files"
         spec.puts "%files"
         gather_sources
         @log.debug "complete file hash:\n#{@filehash.inspect}" if @log.debug?
         ignores = (@conf[:ignore_list] ||= []).map do |ig|
           if ig.is_a? String
             s = ig.strip
             s.prepend('\A') unless s.start_with?('^', '\A')
             s << '\Z' unless s.end_with?('$', '\Z')
             Regexp.new s
           end
         end
         @log.debug "Converted ignore list: #{ignores.inspect}" if @log.debug?

         modes = (@conf[:filemodes] ||= {}).map do |fm|
           if fm.is_a? Hash
             d = (fm['dir'] || fm['file']).strip
             d.prepend('\A') unless d.start_with?('^', '\A')
             d << '\Z' unless d.end_with?('$', '\Z')
             { rgxp: Regexp.new(d), mode: fm['mode'] }
           end
         end
         @log.debug "Converted filemodes: #{modes.inspect}" if @log.debug?
         
         @filehash.each do |dir, files|
            if ignores.any? {|ig| ig.match dir.strip }
              @log.debug "Ignoring #{dir}"
            else
              attribute = ''
              @log.debug "writing attr for #{dir}"
              if @conf.include?(:permissions) and @conf[:permissions].include? dir
                case @conf[:permissions][dir]
                when Array
                  attribute = '(' + @conf[:permissions][dir].join(", ") + ')'
                when Hash
                  attribute = '(' + @conf[:permissions][dir]['mode'] + ', '
                  attribute << @conf[:permissions][dir]['user'] + ', '
                  attribute << @conf[:permissions][dir]['group'] + ')'
                when String
                  attribute = @conf[:permissions][dir]
                else
                  @log.warn "Attribute definition for #{dir} malformed, skipping!"
                end
              else
                attribute = "(#{@conf[:global_dirmode]}, #{@conf[:user]}, #{@conf[:group]})"
              end

              @log.debug "attr will be #{attribute}"
              spec.puts "%dir %attr#{attribute} #{dir}"
            end
              
            files.each do |file|
               if ignores.any? {|ig| ig.match "#{dir}#{file}".strip }
                 @log.debug "Ignoring #{dir}/#{file}"
                 next
               end
               @log.debug "writing attr for #{dir}/#{file}"
               attribute = ''
               if @conf.include?(:permissions) and @conf[:permissions].include? "#{dir}/#{file}"
                  case @conf[:permissions]["#{dir}/#{file}"]
                  when Array
                    attribute = '(' + @conf[:permissions]["#{dir}/#{file}"].join(", ") + ')'
                  when Hash
                    attribute = '(' + @conf[:permissions]["#{dir}/#{file}"]['mode'] + ', '
                    attribute << @conf[:permissions]["#{dir}/#{file}"]['user'] + ', '
                    attribute << @conf[:permissions]["#{dir}/#{file}"]['group'] + ')'
                  when String
                    attribute = @conf[:permissions]["#{dir}/#{file}"]
                  else
                    @log.warn "Attribute definition for #{dir}/#{file} malformed, skipping!"
                  end
               elsif filemode = modes.find {|fm| fm[:rgxp].match(dir.strip) or fm[:rgxp].match(file.strip) }
                  attribute = "(#{filemode[:mode]}, #{@conf[:user]}, #{@conf[:group]})"
               elsif File.basename(dir) == "bin"
		  attribute = "(#{@conf[:bin_filemode]}, #{@conf[:user]}, #{@conf[:group]})"
               elsif File.basename(dir) == "lib"
                  attribute = "(#{@conf[:lib_filemode]}, #{@conf[:user]}, #{@conf[:group]})"
               else
                  attribute = "(#{@conf[:global_filemode]}, #{@conf[:user]}, #{@conf[:group]})"
               end

               next if attribute.nil? or attribute.empty? or /^\s+$/.match(attribute)
               @log.debug "attr will be #{attribute}"
               spec.puts "%attr#{attribute} #{dir}/#{file}" 
            end
         end
      end
   end

   def write_rpmrc
     @log.debug "writing #{@specdir}/rpmrc"
     ((@conf[:rpmrc] ||= {})[:macrofiles] ||= []).push "#{@specdir}/rpmmacros"
     ((@conf[:rpmrc] ||= {})[:macros] ||= []).push "%_topdir #{@root}/rpm", "%_rpmdir #{@root}/rpm/RPMS"
     File.open(File.join(@specdir, "rpmrc"), 'w', 0640) do |rpmrc|
       if @conf.include?(:rpmrc) and @conf[:rpmrc].include?(:macrofiles)
         @log.debug "writing out macrofiles: #{@conf[:rpmrc][:macrofiles].join(':')}" if @log.debug?
         rpmrc.puts "macrofiles: " + @conf[:rpmrc][:macrofiles].join(":")
       end
     end

     @log.debug "writing #{@specdir}/rpmmacros"
     File.open(File.join(@specdir, "rpmmacros"), 'w', 0640) do |rpmmacro|
       if @conf.include?(:rpmrc) and @conf[:rpmrc].include?(:macros)
         @log.debug "writing out macros"
         @conf[:rpmrc][:macros].each {|m| @log.debug "macro: #{m}"; rpmmacro.puts m}
       end
     end
   end

   def gather_sources
      @filehash = {}
      Find.find(@buildroot.chomp("/")) do |path|
         next if path == @buildroot
         if FileTest.directory? path
            Find.prune if /\A\.\.?(svn)?\Z/.match File.basename(path)
            @filehash[path.gsub(/#{@buildroot}/, '')] = []
         else
            next if /\A\.?\.?(\.swp)?(\.ignore)?\Z/.match File.basename(path)
            @filehash[File.dirname(path).gsub(/#{@buildroot}/, '')] << File.basename(path)
         end
      end
      raise RuntimeError, "Could not build filehash from buildroot: #{@buildroot}" if @filehash.empty?
      @filehash
   end

end
