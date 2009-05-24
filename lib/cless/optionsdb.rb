class OptionsDB
  def initialize(*files)
    @names = {}
    @regexps = {}
    files.each { |f| parse_file(f) }
  end

  def parse_file(name)
    File.open(File.expand_path(name)) do |fd|
      fd.each_line do |l|
        a = l.split_with_quotes
        n = a.shift
        r = a.shift
        @names[n] = a
        @regexps[Regexp.new(r)] = a
      end
    end
    true
  end

  def match(fname)
    @regexps.each do |regexp, v|
      return v if fname =~ regexp
    end
    nil
  end

  def [](name); name.nil? ? nil : @names[name]; end
end
