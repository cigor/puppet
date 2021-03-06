require 'puppet'
require 'sync'
require 'getoptlong'
require 'puppet/external/event-loop'
require 'puppet/util/loadedfile'

# The class for handling configuration files.
class Puppet::Util::Settings
  include Enumerable

  require 'puppet/util/settings/setting'
  require 'puppet/util/settings/file_setting'
  require 'puppet/util/settings/boolean_setting'

  attr_accessor :file
  attr_reader :timer

  ReadOnly = [:run_mode, :name]

  # Retrieve a config value
  def [](param)
    value(param)
  end

  # Set a config value.  This doesn't set the defaults, it sets the value itself.
  def []=(param, value)
    set_value(param, value, :memory)
  end

  # Generate the list of valid arguments, in a format that GetoptLong can
  # understand, and add them to the passed option list.
  def addargs(options)
    # Add all of the config parameters as valid options.
    self.each { |name, setting|
      setting.getopt_args.each { |args| options << args }
    }

    options
  end

  # Generate the list of valid arguments, in a format that OptionParser can
  # understand, and add them to the passed option list.
  def optparse_addargs(options)
    # Add all of the config parameters as valid options.
    self.each { |name, setting|
      options << setting.optparse_args
    }

    options
  end

  # Is our parameter a boolean parameter?
  def boolean?(param)
    param = param.to_sym
    !!(@config.include?(param) and @config[param].kind_of? BooleanSetting)
  end

  # Remove all set values, potentially skipping cli values.
  def clear(exceptcli = false)
    @sync.synchronize do
      unsafe_clear(exceptcli)
    end
  end

  # Remove all set values, potentially skipping cli values.
  def unsafe_clear(exceptcli = false)
    @values.each do |name, values|
      @values.delete(name) unless exceptcli and name == :cli
    end

    # Don't clear the 'used' in this case, since it's a config file reparse,
    # and we want to retain this info.
    @used = [] unless exceptcli

    @cache.clear
  end

  # This is mostly just used for testing.
  def clearused
    @cache.clear
    @used = []
  end

  # Do variable interpolation on the value.
  def convert(value, environment = nil)
    return value unless value
    return value unless value.is_a? String
    newval = value.gsub(/\$(\w+)|\$\{(\w+)\}/) do |value|
      varname = $2 || $1
      if varname == "environment" and environment
        environment
      elsif pval = self.value(varname, environment)
        pval
      else
        raise Puppet::DevError, "Could not find value for #{value}"
      end
    end

    newval
  end

  # Return a value's description.
  def description(name)
    if obj = @config[name.to_sym]
      obj.desc
    else
      nil
    end
  end

  def each
    @config.each { |name, object|
      yield name, object
    }
  end

  # Iterate over each section name.
  def eachsection
    yielded = []
    @config.each do |name, object|
      section = object.section
      unless yielded.include? section
        yield section
        yielded << section
      end
    end
  end

  # Return an object by name.
  def setting(param)
    param = param.to_sym
    @config[param]
  end

  # Handle a command-line argument.
  def handlearg(opt, value = nil)
    @cache.clear
    value &&= munge_value(value)
    str = opt.sub(/^--/,'')

    bool = true
    newstr = str.sub(/^no-/, '')
    if newstr != str
      str = newstr
      bool = false
    end
    str = str.intern

    if @config[str].is_a?(Puppet::Util::Settings::BooleanSetting)
      if value == "" or value.nil?
        value = bool
      end
    end

    set_value(str, value, :cli)
  end

  def include?(name)
    name = name.intern if name.is_a? String
    @config.include?(name)
  end

  # check to see if a short name is already defined
  def shortinclude?(short)
    short = short.intern if name.is_a? String
    @shortnames.include?(short)
  end

  # Create a new collection of config settings.
  def initialize
    @config = {}
    @shortnames = {}

    @created = []
    @searchpath = nil

    # Mutex-like thing to protect @values
    @sync = Sync.new

    # Keep track of set values.
    @values = Hash.new { |hash, key| hash[key] = {} }

    # And keep a per-environment cache
    @cache = Hash.new { |hash, key| hash[key] = {} }

    # The list of sections we've used.
    @used = []
  end

  # NOTE: ACS ahh the util classes. . .sigh
  # as part of a fix for 1183, I pulled the logic for the following 5 methods out of the executables and puppet.rb
  # They probably deserve their own class, but I don't want to do that until I can refactor environments
  # its a little better than where they were

  # Prints the contents of a config file with the available config settings, or it
  # prints a single value of a config setting.
  def print_config_options
    env = value(:environment)
    val = value(:configprint)
    if val == "all"
      hash = {}
      each do |name, obj|
        val = value(name,env)
        val = val.inspect if val == ""
        hash[name] = val
      end
      hash.sort { |a,b| a[0].to_s <=> b[0].to_s }.each do |name, val|
        puts "#{name} = #{val}"
      end
    else
      val.split(/\s*,\s*/).sort.each do |v|
        if include?(v)
          #if there is only one value, just print it for back compatibility
          if v == val
            puts value(val,env)
            break
          end
          puts "#{v} = #{value(v,env)}"
        else
          puts "invalid parameter: #{v}"
          return false
        end
      end
    end
    true
  end

  def generate_config
    puts to_config
    true
  end

  def generate_manifest
    puts to_manifest
    true
  end

  def print_configs
    return print_config_options if value(:configprint) != ""
    return generate_config if value(:genconfig)
    generate_manifest if value(:genmanifest)
  end

  def print_configs?
    (value(:configprint) != "" || value(:genconfig) || value(:genmanifest)) && true
  end

  # Return a given object's file metadata.
  def metadata(param)
    if obj = @config[param.to_sym] and obj.is_a?(FileSetting)
      return [:owner, :group, :mode].inject({}) do |meta, p|
        if v = obj.send(p)
          meta[p] = v
        end
        meta
      end
    else
      nil
    end
  end

  # Make a directory with the appropriate user, group, and mode
  def mkdir(default)
    obj = get_config_file_default(default)

    Puppet::Util::SUIDManager.asuser(obj.owner, obj.group) do
      mode = obj.mode || 0750
      Dir.mkdir(obj.value, mode)
    end
  end

  # Figure out the section name for the run_mode.
  def run_mode
    Puppet.run_mode.name
  end

  # Return all of the parameters associated with a given section.
  def params(section = nil)
    if section
      section = section.intern if section.is_a? String
      @config.find_all { |name, obj|
        obj.section == section
      }.collect { |name, obj|
        name
      }
    else
      @config.keys
    end
  end

  # Parse the configuration file.  Just provides
  # thread safety.
  def parse
    raise "No :config setting defined; cannot parse unknown config file" unless self[:config]

    @sync.synchronize do
      unsafe_parse(self[:config])
    end

    # Create a timer so that this file will get checked automatically
    # and reparsed if necessary.
    set_filetimeout_timer
  end

  # Unsafely parse the file -- this isn't thread-safe and causes plenty of problems if used directly.
  def unsafe_parse(file)
    return unless FileTest.exist?(file)
    begin
      data = parse_file(file)
    rescue => details
      puts details.backtrace if Puppet[:trace]
      Puppet.err "Could not parse #{file}: #{details}"
      return
    end

    unsafe_clear(true)

    metas = {}
    data.each do |area, values|
      metas[area] = values.delete(:_meta)
      values.each do |key,value|
        set_value(key, value, area, :dont_trigger_handles => true, :ignore_bad_settings => true )
      end
    end

    # Determine our environment, if we have one.
    if @config[:environment]
      env = self.value(:environment).to_sym
    else
      env = "none"
    end

    # Call any hooks we should be calling.
    settings_with_hooks.each do |setting|
      each_source(env) do |source|
        if value = @values[source][setting.name]
          # We still have to use value to retrieve the value, since
          # we want the fully interpolated value, not $vardir/lib or whatever.
          # This results in extra work, but so few of the settings
          # will have associated hooks that it ends up being less work this
          # way overall.
          setting.handle(self.value(setting.name, env))
          break
        end
      end
    end

    # We have to do it in the reverse of the search path,
    # because multiple sections could set the same value
    # and I'm too lazy to only set the metadata once.
    searchpath.reverse.each do |source|
      source = run_mode if source == :run_mode
      source = @name if (@name && source == :name)
      if meta = metas[source]
        set_metadata(meta)
      end
    end
  end

  # Create a new setting.  The value is passed in because it's used to determine
  # what kind of setting we're creating, but the value itself might be either
  # a default or a value, so we can't actually assign it.
  def newsetting(hash)
    klass = nil
    hash[:section] = hash[:section].to_sym if hash[:section]
    if type = hash[:type]
      unless klass = {:setting => Setting, :file => FileSetting, :boolean => BooleanSetting}[type]
        raise ArgumentError, "Invalid setting type '#{type}'"
      end
      hash.delete(:type)
    else
      case hash[:default]
      when true, false, "true", "false"
        klass = BooleanSetting
      when /^\$\w+\//, /^\//, /^\w:\//
        klass = FileSetting
      when String, Integer, Float # nothing
        klass = Setting
      else
        raise ArgumentError, "Invalid value '#{hash[:default].inspect}' for #{hash[:name]}"
      end
    end
    hash[:settings] = self
    setting = klass.new(hash)

    setting
  end

  # This has to be private, because it doesn't add the settings to @config
  private :newsetting

  # Iterate across all of the objects in a given section.
  def persection(section)
    section = section.to_sym
    self.each { |name, obj|
      if obj.section == section
        yield obj
      end
    }
  end

  def file
    return @file if @file
    if path = self[:config] and FileTest.exist?(path)
      @file = Puppet::Util::LoadedFile.new(path)
    end
  end

  # Reparse our config file, if necessary.
  def reparse
    if file and file.changed?
      Puppet.notice "Reparsing #{file.file}"
      parse
      reuse
    end
  end

  def reuse
    return unless defined?(@used)
    @sync.synchronize do # yay, thread-safe
      new = @used
      @used = []
      self.use(*new)
    end
  end

  # The order in which to search for values.
  def searchpath(environment = nil)
    if environment
      [:cli, :memory, environment, :run_mode, :main, :mutable_defaults]
    else
      [:cli, :memory, :run_mode, :main, :mutable_defaults]
    end
  end

  # Get a list of objects per section
  def sectionlist
    sectionlist = []
    self.each { |name, obj|
      section = obj.section || "puppet"
      sections[section] ||= []
      sectionlist << section unless sectionlist.include?(section)
      sections[section] << obj
    }

    return sectionlist, sections
  end

  def service_user_available?
    return @service_user_available if defined?(@service_user_available)

    return @service_user_available = false unless user_name = self[:user]

    user = Puppet::Type.type(:user).new :name => self[:user], :audit => :ensure

    @service_user_available = user.exists?
  end

  def legacy_to_mode(type, param)
    if not defined?(@app_names)
      require 'puppet/util/command_line'
      command_line = Puppet::Util::CommandLine.new
      @app_names = Puppet::Util::CommandLine::LegacyName.inject({}) do |hash, pair|
        app, legacy = pair
        command_line.require_application app
        hash[legacy.to_sym] = Puppet::Application.find(app).run_mode.name
        hash
      end
    end
    if new_type = @app_names[type]
      Puppet.warning "You have configuration parameter $#{param} specified in [#{type}], which is a deprecated section. I'm assuming you meant [#{new_type}]"
      return new_type
    end
    type
  end

  def set_value(param, value, type, options = {})
    param = param.to_sym
    unless setting = @config[param]
      if options[:ignore_bad_settings]
        return
      else
        raise ArgumentError,
          "Attempt to assign a value to unknown configuration parameter #{param.inspect}"
      end
    end
    value = setting.munge(value) if setting.respond_to?(:munge)
    setting.handle(value) if setting.respond_to?(:handle) and not options[:dont_trigger_handles]
    if ReadOnly.include? param and type != :mutable_defaults
      raise ArgumentError,
        "You're attempting to set configuration parameter $#{param}, which is read-only."
    end
    type = legacy_to_mode(type, param)
    @sync.synchronize do # yay, thread-safe
      @values[type][param] = value
      @cache.clear

      clearused

      # Clear the list of environments, because they cache, at least, the module path.
      # We *could* preferentially just clear them if the modulepath is changed,
      # but we don't really know if, say, the vardir is changed and the modulepath
      # is defined relative to it. We need the defined?(stuff) because of loading
      # order issues.
      Puppet::Node::Environment.clear if defined?(Puppet::Node) and defined?(Puppet::Node::Environment)
    end

    value
  end

  # Set a bunch of defaults in a given section.  The sections are actually pretty
  # pointless, but they help break things up a bit, anyway.
  def setdefaults(section, defs)
    section = section.to_sym
    call = []
    defs.each { |name, hash|
      if hash.is_a? Array
        unless hash.length == 2
          raise ArgumentError, "Defaults specified as an array must contain only the default value and the decription"
        end
        tmp = hash
        hash = {}
        [:default, :desc].zip(tmp).each { |p,v| hash[p] = v }
      end
      name = name.to_sym
      hash[:name] = name
      hash[:section] = section
      raise ArgumentError, "Parameter #{name} is already defined" if @config.include?(name)
      tryconfig = newsetting(hash)
      if short = tryconfig.short
        if other = @shortnames[short]
          raise ArgumentError, "Parameter #{other.name} is already using short name '#{short}'"
        end
        @shortnames[short] = tryconfig
      end
      @config[name] = tryconfig

      # Collect the settings that need to have their hooks called immediately.
      # We have to collect them so that we can be sure we're fully initialized before
      # the hook is called.
      call << tryconfig if tryconfig.call_on_define
    }

    call.each { |setting| setting.handle(self.value(setting.name)) }
  end

  # Create a timer to check whether the file should be reparsed.
  def set_filetimeout_timer
    return unless timeout = self[:filetimeout] and timeout = Integer(timeout) and timeout > 0
    timer = EventLoop::Timer.new(:interval => timeout, :tolerance => 1, :start? => true) { self.reparse }
  end

  # Convert the settings we manage into a catalog full of resources that model those settings.
  def to_catalog(*sections)
    sections = nil if sections.empty?

    catalog = Puppet::Resource::Catalog.new("Settings")

    @config.values.find_all { |value| value.is_a?(FileSetting) }.each do |file|
      next unless (sections.nil? or sections.include?(file.section))
      next unless resource = file.to_resource
      next if catalog.resource(resource.ref)

      catalog.add_resource(resource)
    end

    add_user_resources(catalog, sections)

    catalog
  end

  # Convert our list of config settings into a configuration file.
  def to_config
    str = %{The configuration file for #{Puppet[:name]}.  Note that this file
is likely to have unused configuration parameters in it; any parameter that's
valid anywhere in Puppet can be in any config file, even if it's not used.

Every section can specify three special parameters: owner, group, and mode.
These parameters affect the required permissions of any files specified after
their specification.  Puppet will sometimes use these parameters to check its
own configured state, so they can be used to make Puppet a bit more self-managing.

Generated on #{Time.now}.

}.gsub(/^/, "# ")

#         Add a section heading that matches our name.
if @config.include?(:run_mode)
  str += "[#{self[:run_mode]}]\n"
    end
    eachsection do |section|
      persection(section) do |obj|
        str += obj.to_config + "\n" unless ReadOnly.include? obj.name or obj.name == :genconfig
      end
    end

    return str
  end

  # Convert to a parseable manifest
  def to_manifest
    catalog = to_catalog
    catalog.resource_refs.collect do |ref|
      catalog.resource(ref).to_manifest
    end.join("\n\n")
  end

  # Create the necessary objects to use a section.  This is idempotent;
  # you can 'use' a section as many times as you want.
  def use(*sections)
    sections = sections.collect { |s| s.to_sym }
    @sync.synchronize do # yay, thread-safe
      sections = sections.reject { |s| @used.include?(s) }

      return if sections.empty?

      begin
        catalog = to_catalog(*sections).to_ral
      rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.err "Could not create resources for managing Puppet's files and directories in sections #{sections.inspect}: #{detail}"

        # We need some way to get rid of any resources created during the catalog creation
        # but not cleaned up.
        return
      end

      catalog.host_config = false
      catalog.apply do |transaction|
        if transaction.any_failed?
          report = transaction.report
          failures = report.logs.find_all { |log| log.level == :err }
          raise "Got #{failures.length} failure(s) while initializing: #{failures.collect { |l| l.to_s }.join("; ")}"
        end
      end

      sections.each { |s| @used << s }
      @used.uniq!
    end
  end

  def valid?(param)
    param = param.to_sym
    @config.has_key?(param)
  end

  def uninterpolated_value(param, environment = nil)
    param = param.to_sym
    environment &&= environment.to_sym

    # See if we can find it within our searchable list of values
    val = catch :foundval do
      each_source(environment) do |source|
        # Look for the value.  We have to test the hash for whether
        # it exists, because the value might be false.
        @sync.synchronize do
          throw :foundval, @values[source][param] if @values[source].include?(param)
        end
      end
      throw :foundval, nil
    end

    # If we didn't get a value, use the default
    val = @config[param].default if val.nil?

    val
  end

  # Find the correct value using our search path.  Optionally accept an environment
  # in which to search before the other configuration sections.
  def value(param, environment = nil)
    param = param.to_sym
    environment &&= environment.to_sym

    # Short circuit to nil for undefined parameters.
    return nil unless @config.include?(param)

    # Yay, recursion.
    #self.reparse unless [:config, :filetimeout].include?(param)

    # Check the cache first.  It needs to be a per-environment
    # cache so that we don't spread values from one env
    # to another.
    if cached = @cache[environment||"none"][param]
      return cached
    end

    val = uninterpolated_value(param, environment)

    if param == :code
      # if we interpolate code, all hell breaks loose.
      return val
    end

    # Convert it if necessary
    val = convert(val, environment)

    # And cache it
    @cache[environment||"none"][param] = val
    val
  end

  # Open a file with the appropriate user, group, and mode
  def write(default, *args, &bloc)
    obj = get_config_file_default(default)
    writesub(default, value(obj.name), *args, &bloc)
  end

  # Open a non-default file under a default dir with the appropriate user,
  # group, and mode
  def writesub(default, file, *args, &bloc)
    obj = get_config_file_default(default)
    chown = nil
    if Puppet.features.root?
      chown = [obj.owner, obj.group]
    else
      chown = [nil, nil]
    end

    Puppet::Util::SUIDManager.asuser(*chown) do
      mode = obj.mode ? obj.mode.to_i : 0640
      args << "w" if args.empty?

      args << mode

      # Update the umask to make non-executable files
      Puppet::Util.withumask(File.umask ^ 0111) do
        File.open(file, *args) do |file|
          yield file
        end
      end
    end
  end

  def readwritelock(default, *args, &bloc)
    file = value(get_config_file_default(default).name)
    tmpfile = file + ".tmp"
    sync = Sync.new
    raise Puppet::DevError, "Cannot create #{file}; directory #{File.dirname(file)} does not exist" unless FileTest.directory?(File.dirname(tmpfile))

    sync.synchronize(Sync::EX) do
      File.open(file, ::File::CREAT|::File::RDWR, 0600) do |rf|
        rf.lock_exclusive do
          if File.exist?(tmpfile)
            raise Puppet::Error, ".tmp file already exists for #{file}; Aborting locked write. Check the .tmp file and delete if appropriate"
          end

          # If there's a failure, remove our tmpfile
          begin
            writesub(default, tmpfile, *args, &bloc)
          rescue
            File.unlink(tmpfile) if FileTest.exist?(tmpfile)
            raise
          end

          begin
            File.rename(tmpfile, file)
          rescue => detail
            Puppet.err "Could not rename #{file} to #{tmpfile}: #{detail}"
            File.unlink(tmpfile) if FileTest.exist?(tmpfile)
          end
        end
      end
    end
  end

  private

  def get_config_file_default(default)
    obj = nil
    unless obj = @config[default]
      raise ArgumentError, "Unknown default #{default}"
    end

    raise ArgumentError, "Default #{default} is not a file" unless obj.is_a? FileSetting

    obj
  end

  # Create the transportable objects for users and groups.
  def add_user_resources(catalog, sections)
    return unless Puppet.features.root?
    return if Puppet.features.microsoft_windows?
    return unless self[:mkusers]

    @config.each do |name, setting|
      next unless setting.respond_to?(:owner)
      next unless sections.nil? or sections.include?(setting.section)

      if user = setting.owner and user != "root" and catalog.resource(:user, user).nil?
        resource = Puppet::Resource.new(:user, user, :parameters => {:ensure => :present})
        resource[:gid] = self[:group] if self[:group]
        catalog.add_resource resource
      end
      if group = setting.group and ! %w{root wheel}.include?(group) and catalog.resource(:group, group).nil?
        catalog.add_resource Puppet::Resource.new(:group, group, :parameters => {:ensure => :present})
      end
    end
  end

  # Yield each search source in turn.
  def each_source(environment)
    searchpath(environment).each do |source|
      # Modify the source as necessary.
      source = self.run_mode if source == :run_mode
      yield source
    end
  end

  # Return all settings that have associated hooks; this is so
  # we can call them after parsing the configuration file.
  def settings_with_hooks
    @config.values.find_all { |setting| setting.respond_to?(:handle) }
  end

  # Extract extra setting information for files.
  def extract_fileinfo(string)
    result = {}
    value = string.sub(/\{\s*([^}]+)\s*\}/) do
      params = $1
      params.split(/\s*,\s*/).each do |str|
        if str =~ /^\s*(\w+)\s*=\s*([\w\d]+)\s*$/
          param, value = $1.intern, $2
          result[param] = value
          raise ArgumentError, "Invalid file option '#{param}'" unless [:owner, :mode, :group].include?(param)

          if param == :mode and value !~ /^\d+$/
            raise ArgumentError, "File modes must be numbers"
          end
        else
          raise ArgumentError, "Could not parse '#{string}'"
        end
      end
      ''
    end
    result[:value] = value.sub(/\s*$/, '')
    result
  end

  # Convert arguments into booleans, integers, or whatever.
  def munge_value(value)
    # Handle different data types correctly
    return case value
      when /^false$/i; false
      when /^true$/i; true
      when /^\d+$/i; Integer(value)
      when true; true
      when false; false
      else
        value.gsub(/^["']|["']$/,'').sub(/\s+$/, '')
    end
  end

  # This method just turns a file in to a hash of hashes.
  def parse_file(file)
    text = read_file(file)

    result = Hash.new { |names, name|
      names[name] = {}
    }

    count = 0

    # Default to 'main' for the section.
    section = :main
    result[section][:_meta] = {}
    text.split(/\n/).each { |line|
      count += 1
      case line
      when /^\s*\[(\w+)\]\s*$/
        section = $1.intern # Section names
        # Add a meta section
        result[section][:_meta] ||= {}
      when /^\s*#/; next # Skip comments
      when /^\s*$/; next # Skip blanks
      when /^\s*(\w+)\s*=\s*(.*?)\s*$/ # settings
        var = $1.intern

        # We don't want to munge modes, because they're specified in octal, so we'll
        # just leave them as a String, since Puppet handles that case correctly.
        if var == :mode
          value = $2
        else
          value = munge_value($2)
        end

        # Check to see if this is a file argument and it has extra options
        begin
          if value.is_a?(String) and options = extract_fileinfo(value)
            value = options[:value]
            options.delete(:value)
            result[section][:_meta][var] = options
          end
          result[section][var] = value
        rescue Puppet::Error => detail
          detail.file = file
          detail.line = line
          raise
        end
      else
        error = Puppet::Error.new("Could not match line #{line}")
        error.file = file
        error.line = line
        raise error
      end
    }

    result
  end

  # Read the file in.
  def read_file(file)
    begin
      return File.read(file)
    rescue Errno::ENOENT
      raise ArgumentError, "No such file #{file}"
    rescue Errno::EACCES
      raise ArgumentError, "Permission denied to file #{file}"
    end
  end

  # Set file metadata.
  def set_metadata(meta)
    meta.each do |var, values|
      values.each do |param, value|
        @config[var].send(param.to_s + "=", value)
      end
    end
  end
end
