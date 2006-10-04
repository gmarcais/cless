# Read from a stream. Write data to a temporary file, which is mmap.
# Read more data from stream on a need basis, when some index  operation fail.
class MappedStream
  DEFAULTS = {
    :buf_size => 64*1024,
    :tmp_dir => Dir.tmpdir,
  }
  attr_reader :ptr, :more
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
  def index(substr, off = 0)
    loop do
      r = @ptr.index(substr, off) and return r
      return nil unless @more
      off = (@ptr.rindex("\n", @ptr.size) || -1) + 1
      begin
        @fd.sysread(@buf_size, @buf)
        @ptr << @buf
      rescue EOFError
        @more = false
      end
    end
  end
  def [](*args); @ptr[*args]; end

  def lines
    return @lines if @lines
    @lines = @ptr.count("\n")
    while @more
      begin 
        @fd.sysread(@buf_size, @buf)
        @ptr << @buf
        @lines += @buf.count("\n")
      rescue EOFError
        @more = false
      end
    end
    @lines += 1 if @ptr[-1] != ?\n
    return @lines
  end
end

class MappedFile
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
  
  def lines
    return @lines if @lines
    @lines = @ptr.count("\n")
    @lines += 1 if @ptr[-1] != ?\n
    return @lines
  end
end

class Line
  attr_reader :has_match

  def initialize(a)
    @a = a
    @m = []
    @has_match = false
  end

  def values_at(*args); @a.values_at(*args); end
  def matches_at(*args); @m.values_at(*args); end

  def match(pattern)
    does_match = false
    @a.each_with_index { |f, i|
      if m = f.match(pattern)
        does_match = true
        @m[i] = m
      end
    }
    @has_match = does_match
  end

  def clear_match; @has_match = false; @m.clear; end
end

class MapData
  attr_reader :sizes, :line, :line2, :pattern
  def initialize(str)
    @str = str
    @line = @line2 = 0
    @off = @off2 = 0    # @off = first character of first line in cache
                        # @off = first character of first line past cache
    @cache = []
    @sizes = []
    @pattern = nil      # search pattern
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
    @off = @off2 = (@str.rindex("\n", @str.size-1) || -1) + 1
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
      @line += skip_forward(delta) 
      @cache.slice!(0, delta)
      cache_forward(@line2 - @line - @cache.size)
    else
      @line2 -= skip_backward(-delta)
      delta = -@cache.size if -delta > @cache.size
      @cache.slice!((delta..-1))
      cache_backward(cache_size - @cache.size)
    end
  end

  def shift_column(delta)
    return if delta == 0
    if delta > 0
      if @column < @sizes.size
        @coff += @sizes[@column] + 1
        @column += 1
      end
    else
      if @column > 0
        @column -= 1
        @coff -= @sizes[@column] + 1
      end
    end
  end

  def cache_fill(n)
    cache_forward(n - @cache.size) if @cache.size < n
  end

  def clear_cache
    @cache.clear
    @line2 = @line
    @off2 = @off
    @sizes.clear
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

  def cache_forward(n)
    n.times do
      noff2 = @str.index("\n", @off2) or break
      nl = @str[@off2..(noff2-1)].split
      @sizes.max_update(nl.collect { |x| x.size })
      @cache << (l = Line.new(nl))
      l.match(@pattern) if @pattern
      @off2 = noff2 + 1
    end
    @line2 = @line + @cache.size
  end

  def cache_backward(n)
    n.times do
      break if @off < 2
      noff = (@str.rindex("\n", @off-2) || -1) + 1
      nl = @str[noff..(@off-2)].split
      @sizes.max_update(nl.collect { |x| x.size })
      @cache.unshift(l = Line.new(nl))
      l.match(@pattern) if @pattern
      @off = noff
    end
    @line = @line2 - @cache.size
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
    i
  end

  # Move @off2 back by n lines. Make sure that @off <= @off2
  def skip_backward(n)
    i = 0
    n.times do
      break if @off2 < 2
      @off2 = (@str.rindex("\n", @off2-2) || -1) + 1
      i += 1
    end
    @off = @off2 if @off > @off2
    i
  end
end
