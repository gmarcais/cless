class NameDB
  def initialize(*files)
    @names = {}
    files.each { |f| parse_file(f) }
  end

  def parse_file(name)
    File.open(File.expand_path(name)) do |fd|
      fd.each_line do |l|
        a = l.split
        n = a.shift
        @names[Regexp.new("#{Regexp.quote(n)}$")] = a if n
      end
    end
    true
  end

  def find(name)
    @names.each do |n, v|
      return v if n =~ name
    end
    nil
  end
end