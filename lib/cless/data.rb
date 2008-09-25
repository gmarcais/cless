# Including class must respond to #each_line
module MappedCommon
  def parse_header(allowed = [])
    a = []
    i = 0
    each_line do |l|
      break unless l =~ %r{^\s*#(.*)$}
      i += 1
      s = $1
      case s
      when /^\s*cless:(.*)$/
        s = $1.strip
        a += s.split_with_quotes
      when /^\s*(\w+):(.*)$/
        k, v = $1.strip, $2.strip
        a << "--#{k}" << v if allowed.include?(k)
      end
    end
    return i, a
  end

  def count_lines_upto(stop_off)
    cur = 0
    nb = 0
    while cur <= stop_off do
      cur = @ptr.index("\n", cur)
      if cur
        cur += 1
        nb += 1
      else
        break
      end
    end
    nb
  end
end

# Read from a stream. Write data to a temporary file, which is mmap.
# Read more data from stream on a need basis, when some index  operation fail.
class MappedStream
  include MappedCommon

  DEFAULTS = {
    :buf_size => 64*1024,
    :tmp_dir => Dir.tmpdir,
  }
  attr_reader :ptr, :more, :fd
  def initialize(fd, args = {})
    @fd = fd
    @more = true
    @buf = ""
    @line = nil

    DEFAULTS.each { |k, v|
      instance_variable_set("@#{k}", args[k] || v)
    }
    @tfd = Tempfile.new(Process.pid.to_s, @tmp_dir)
    @ptr = Mmap.new(@tfd.path, "w")
    @ptr.extend(10 * @buf_size)

    if block_given?
      begin
        yield(self)
      ensure
        munmap
      end
    end
  end

  def file_path; @tfd.path; end

  def munmap
    @ptr.munmap
    @tfd.close!
  end

  def size; @ptr.size; end
  def rindex(*args); @ptr.rindex(*args); end
  
  def read_block
    @fd.read_nonblock(@buf_size, @buf)
    @ptr << @buf
  rescue Errno::EAGAIN, Errno::EINTR
    false
  rescue EOFError
    @more = false
    false
  end
    

  def index(substr, off = 0)
    loop do
      r = @ptr.index(substr, off) and return r
      return nil unless @more
      off = (@ptr.rindex("\n", @ptr.size) || -1) + 1
      read_block or return nil
    end
  end
  def [](*args); @ptr[*args]; end

  # Get the total number of lines
  # Stop if line_stop or offset_stop limits are crossed.
  def lines(line_stop = nil, offset_stop = nil)
    return @lines unless @more
    lines = @ptr.count("\n")
    while @more
      read_block or break
      lines += @buf.count("\n")
      return lines if line_stop && lines >= line_stop
      return @ptr.size if offset_stop && @ptr.size >= offset_stop
    end
    @lines = lines
    @lines += 1 if @ptr[-1] != ?\n
    return @lines
  end

  def each_line
    off = 0
    loop do
      r = @ptr.index("\n", off)
      if r
        yield(@ptr[off..r])
        off = r + 1
      else
        read_block or break
      end
    end
  end
end

class MappedFile
  include MappedCommon

  attr_reader :file_path

  def initialize(fname)
    @ptr = Mmap.new(fname)
    @lines = nil
    @file_path = fname

    if block_given?
      begin
        yield(self)
      ensure
        munmap
      end
    end
  end

  def size; @ptr.size; end
  def munmap; @ptr.munmap; end
  def rindex(*args); @ptr.rindex(*args); end
  def index(*args); @ptr.index(*args); end
  def [](*args); @ptr[*args]; end
  def each_line(&b); @ptr.each_line(&b); end

  def lines
    return @lines if @lines
    @lines = @ptr.count("\n")
    @lines += 1 if @ptr[-1] != ?\n
    return @lines
  end
end

# Similar interface to MatchData. Return the entire string as being a match.
class FieldMatch
  def initialize(str); @str = str; end
  def string; @str; end
  def pre_match; ""; end
  def post_match; ""; end
  def [](i); (i == 0) ? @str : nil; end
end

class Line
  attr_reader :has_match, :off
  attr_accessor :highlight
  alias :highlight? :highlight

  def initialize(a, onl = nil, off = nil)
    @a, @onl = a, onl
    @m = []
    @has_match = false
    @off = off
    @highlight = false
  end

  def ignored; false; end
  alias :ignored? :ignored

  def values_at(*args); @a.values_at(*args); end
  def matches_at(*args); @m.values_at(*args); end

  # onl is the line before any formatting or transformation.
  # If a field doesn't match pattern but old representation does,
  # hilight entire field as a match.
  def match(pattern)
    does_match = false
    @a.each_with_index { |f, i|
      if m = f.match(pattern)
        does_match = true
        @m[i] = m
      elsif @onl && @onl[i].match(pattern)
        does_match = true
        @m[i] = FieldMatch.new(f)
      end
    }
    @has_match = does_match
  end

  def clear_match; @has_match = false; @m.clear; end
end

class IgnoredLine
  attr_reader :has_match, :str, :off

  def initialize(str, off)
    @str = str
    @has_match = false
    @off = off                  # Byte offset in file of beginning of line
  end

  def match(pattern)
    if m = @str.match(pattern)
      @m = m
      @has_match = true
    end
  end

  def matches; @m; end
  def clear_match; @has_match = false; @m = nil; end

  def ignored; true; end
  alias :ignored? :ignored

  # An ignored line is never highlighted
  def highlight; false; end
  alias :highlight? :highlight

  def highlight=(*args); end
end

class MapData
  attr_reader :sizes, :line, :line2, :pattern, :split_regexp
  def initialize(str, split_regexp = nil)
    @str = str
    @line = @line2 = 0
    @off = @off2 = 0    # @off  = first character of first line in cache
                        # @off2 = first character of first line past cache
    @cache = []
    @sizes = []
    @pattern = nil      # search pattern
    @formats = nil      # formating strings. When not nil, a hash.
    @ignores = nil      # line ignored index or pattern.
    @split_regexp = split_regexp        # split pattern
    @highlight_regexp = nil             # highlight pattern
    @need_more = false  # true if last cache_fill needs data
  end

  def file_path; @str.file_path; end
  def write_to(fd)
    @str.lines          # Make sure we have all the data
    block = 64*1024

    (@str.size / block).times do |i|
      fd.syswrite(@str[i*block, block])
    end
    if (r = @str.size % block) > 0
      fd.syswrite(@str[@str.size - r, r])
    end
    @str.size
  end

  def select_fd
    if @need_more && @str.respond_to?(:more) && @str.respond_to?(:fd)
      @str.more ? @str.fd : nil
    else
      nil
    end
  end

  # yield n lines with length len to be displayed
  def lines(n)
    @cache.each_with_index { |l, i|
      break if i >= n
      yield l
    }
  end

  def goto_start
    @line = @line2 = 0
    @off = @off2 = 0
    @cache.clear
  end

  def goto_end
    @line = @line2 = @str.lines
    @off2 = @off = @str.size
    cache_size = @cache.size
    @cache.clear
    scroll(-cache_size)
  end

  def goto_line(nb)
    delta = nb - @line - 1
    scroll(delta)
  end

  def goto_percent(percent)
    percent = 0.0 if percent < 0.0
    percent = 100.0 if percent > 100.0
    percent = percent.to_f
    line = (@str.lines * percent / 100).round
    goto_line(line)
  end

  def goto_offset(off)
    @str.lines(nil, off) if off > @str.size
    off -= 1 if @str[off] == ?\n && off > 0
    @off = @off2 = (@str.rindex("\n", off) || -1) + 1
    @line = @line2 = @str.count_lines_upto(@off)
    @cache.clear
  end

  # Return true if pattern found, false otherwise
  def search(pattern, dir = :forward)
    search_clear if @pattern
    @pattern = pattern
    first_line = nil
    cache = (dir == :forward) ? @cache : @cache.reverse
    cache.each_with_index { |l, i|
      l.match(@pattern) and first_line ||= i
    }
    if first_line
      scroll((dir == :forward) ? first_line : -first_line)
      return true
    else
      return search_next(dir)
    end
  end

  def repeat_search(dir = :forward)
    first_line = nil
    cache = (dir == :forward) ? @cache : @cache.reverse
    cache[1..-1].each_with_index { |l, i|
      if l.has_match
        first_line = i
        break
      end
    }
    if first_line
      scroll((dir == :forward) ? first_line + 1 : -first_line - 1)
      return true
    else
      return search_next(dir)
    end
  end

  def search_clear
    @pattern = nil
    @cache.each { |l| l.clear_match }
  end

  # delta > for scrolling down (forward in file)
  def scroll(delta)
    return if delta == 0
    cache_size = @cache.size
    if delta > 0
      skipped = skip_forward(delta) 
      @cache.slice!(0, skipped)
      cache_forward([cache_size, skipped].min)
    else
      skipped = skip_backward(-delta)
      delta = -@cache.size if -delta > @cache.size
      @cache.slice!((delta..-1))
      cache_backward([cache_size, skipped].min)
    end
  end

  def cache_fill(n)
    @need_more = @cache.size < n
    cache_forward(n - @cache.size) if @need_more
  end

  def clear_cache
    @cache.clear
    @line2 = @line
    @off2 = @off
    @sizes.clear
  end

  def refresh
    size = @cache.size
    clear_cache
    cache_fill(size)
  end

  FMT_LETTERS = "bcdEefGgiIosuXx"
  FMT_REGEXP = /(^|[^%])(%[ \d#+*.-]*)([#{FMT_LETTERS}])/
  FLOAT_PROC = proc { |x| x.to_f }
  INT_PROC = proc { |x| x.to_i }
  BIGINT_PROC = proc { |x| x.reverse.gsub(/(...)/, '\1,').chomp(",").reverse }
  def set_format_column(fmt, *cols)
    a = [fmt]
    if fmt =~ FMT_REGEXP
      case $3
      when "b", "c", "d", "i", "o", "u", "X", "x": a << INT_PROC
      when "E", "e", "f", "G", "g": a << FLOAT_PROC
      when "I": a = ["#{$`}#{$1}#{$2}s#{$'}", BIGINT_PROC]
      end
    end
    @formats ||= {}
    cols.each { |c| @formats[c] = a }
    true
  end

  def unset_format_column(col)
    return nil unless @formats
    r = @formats.delete(col)
    @formats = nil if @formats.empty?
    r
  end

  def get_format_column(col)
    return nil unless @formats
    @formats[col]
  end

  def formatted_column_list; @formats ? @formats.keys : []; end

  def add_ignore(pattern)
    return nil unless [Fixnum, Range, Regexp].any? { |c| c === pattern }
    (@ignored ||= []) << pattern
    true
  end

  def split_regexp=(regexp)
    @split_regexp = regexp
    clear_cache
  end

  def highlight_regexp=(regexp)
    @highlight_regexp = regexp
    clear_cache
  end

  def remove_ignore(pattern)
    if pattern.nil?
      r, @ignored = @ignored, nil
      return r
    end
    return nil unless [Fixnum, Range, Regexp].any? { |c| c === pattern }
    r = @ignored.delete(pattern)
    @ignored = nil if @ignored.empty?
    r
  end

  def ignore_pattern_list; @ignored ? @ignored : []; end

  # Returns the maximum line offset of all lines in cache
  def max_offset
    @cache.collect { |l| l.off }.max
  end

  private
  def search_next(dir = :forward)
    if dir == :forward
      m = @str.index(@pattern, @off2)
    else
      m = @str.rindex(@pattern, @off)
    end
    return false if !m
    if dir == :forward
      old_off2, old_line2 = @off2, @line2
      @off = @off2 = (@str.rindex("\n", m) || -1) + 1
      @line = @line2 = old_line2 + @str[old_off2..@off2].count("\n")
      @cache.clear
    else
      old_off, old_line = @off, @line
      @off = @off2 = (@str.rindex("\n", m) || -1) + 1
      @line = @line2 = old_line - @str[@off..old_off].count("\n")
      cache_size = @cache.size
      @cache.clear
      scroll(-cache_size+1)
    end
    return true
  end

  def reformat(nl)
    onl = nl.dup
    @formats.each do |i, f|
      s = nl[i] or next
      fmt, proc = *f
      s = proc[s] if proc
      nl[i] = fmt % s rescue "###"
    end
    onl
  end

  def line_ignore?(str, i)
    @ignored.any? do |pat|
      case pat
      when Range, Fixnum: pat === i
      when Regexp: pat === str
      else false
      end
    end
  end

  # str = line
  # i = line number
  def line_massage(str, i, off)
    if @ignored && line_ignore?(str, i)
      l = IgnoredLine.new(str, off)
    else
      onl, nl = nil, str.split(@split_regexp)
      onl = reformat(nl) if @formats
      @sizes.max_update(nl.collect { |x| x.size })
      l = Line.new(nl, onl, off)
    end
    l.match(@pattern) if @pattern
    l.highlight = @highlight_regexp && (@highlight_regexp =~ str)
    l
  end

  def cache_forward(n)
    lnb = @line + @cache.size
    n.times do |i|
      noff2 = @str.index("\n", @off2) or break
      @cache << line_massage(@str[@off2, noff2 - @off2], lnb + i, @off2)
      @off2 = noff2 + 1
    end
    @line2 = @line + @cache.size
  end

  def cache_backward(n)
    lnb = @line - 1
    n.times do |i|
      break if @off == 0
      ooff = @off
      @off = search_backward_to_new_line(@off)
      @cache.unshift(line_massage(@str[@off, ooff - @off - 1], lnb - i, @off))
    end
    @line = @line2 - @cache.size
  end

  def search_backward_to_new_line(start)
    return 0 if start < 2
    npos = @str.rindex("\n", start - 2)
    return npos ? npos + 1 : 0
  end

  # Move @off by n lines. Make sure that @off2 >= @off
  def skip_forward(n)
    i = 0
    n.times do 
      noff = @str.index("\n", @off) or break
      @off = noff + 1
      i += 1
    end
    @off2 = @off if @off2 < @off
    @line += i
    @line2 = @line if @line > @line2
    i
  end

  # Move @off2 back by n lines. Make sure that @off <= @off2
  def skip_backward(n)
    i = 0
    n.times do
      break if @off2 == 0
      @off2 = search_backward_to_new_line(@off2)
      i += 1
    end
    @off = @off2 if @off > @off2
    @line2 -= i
    @line = @line2 if @line2 < @line
    i
  end
end
