require 'ncurses'
require 'mmap'
require 'tempfile'
require 'mmap'

class Array
  def max_update(a)
    a.each_with_index { |x, i|
      self[i] = x if !(v = self[i]) || v < x
    }
  end
end

def curses_init
  Ncurses.initscr
  Ncurses.start_color
  Ncurses.raw
  Ncurses.noecho
  Ncurses.nonl
  Ncurses.stdscr.intrflush(false)
  Ncurses.stdscr.immedok(false)
  Ncurses.keypad(Ncurses.stdscr, true)

  Ncurses.init_pair(1, Ncurses::COLOR_BLACK, Ncurses::COLOR_WHITE)
  Ncurses.init_pair(2, Ncurses::COLOR_BLACK, Ncurses::COLOR_WHITE)
end

def curses_close
  Ncurses.endwin
end

def wait_for_key(data, display)
  loop do
    case k = Ncurses.getch
    when Ncurses::KEY_DOWN: data.scroll(1); break
    when Ncurses::KEY_UP: data.scroll(-1); break
    when Ncurses::KEY_NPAGE: data.scroll(Ncurses.stdscr.getmaxy - 1); break
    when Ncurses::KEY_PPAGE: data.scroll(1 - Ncurses.stdscr.getmaxy); break
    when Ncurses::KEY_LEFT: data.shift_column(-1); break
    when Ncurses::KEY_RIGHT: data.shift_column(1); break
    when ?h: display.hilights = !display.hilights; break
    when ?c: display.column = !display.column; break
    when Ncurses::KEY_RESIZE: break
    when ?q: return nil
    else 
      $log.puts(k)
    end
  end
  return true
end

class LineDisplay
  DEFAULTS = {
    :hilights => true,          # Wether to hilight every other line
    :column => false,            # Wether to display column number
  }
  attr_accessor *DEFAULTS.keys

  def initialize(data, args = {})
    DEFAULTS.each { |k, v|
      instance_variable_set("@#{k}", args[k] || v)
    }
    @data = data
  end

  def lines; Ncurses.stdscr.getmaxy; end

  def refresh
    len = Ncurses.stdscr.getmaxx
    lines = Ncurses.stdscr.getmaxy - 1
    sizes = @data.sizes.dup
    format = "%*s " * sizes.size
    

    Ncurses.move(0, 0)
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    if @column
      lines -= 1
      cheader = (1..sizes.size).collect { |x| x.to_s }
      sizes.max_update(cheader.collect { |x| x.size })
      i = -1
      cheader.collect! { |x| i += 1; x.center(sizes[i]) }
      s = (format % sizes.zip(cheader).flatten)[0, len]
      Ncurses.addstr(s)
    end
    i = 0
    @data.lines(lines) { |l|
      Ncurses.attrset(Ncurses.COLOR_PAIR(i % 2)) if @hilights
      $log.puts([i, l].inspect)
      s = (format % sizes.zip(l).flatten)[0, len]
      $log.puts(s)
      Ncurses.addstr(s)
      i += 1
    }
    if i < lines
      Ncurses.attrset(Ncurses.COLOR_PAIR(0))
      Ncurses.addstr(" " * (len * (lines - i)))
    end
  ensure
    Ncurses.refresh
  end
end

# Read from a stream. Write data to a temporary file, which is mmap.
# Read more data from stream on a need basis, when some index  operation fail.
class MappedStream
  DEFAULTS = {
    :buf_size => 64*1024,
  }
  attr_reader :ptr, :more
  def initialize(fd, args = {})
    @fd = fd
    @more = true
    @buf = ""
    DEFAULTS.each { |k, v|
      instance_variable_set("@#{k}", args[k] || v)
    }
    @tfd = Tempfile.new(Process.pid.to_s)
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

  def munmap
    @ptr.munmap
    @tfd.close!
  end

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
end

class MapData
  attr_reader :sizes
  def initialize(str)
    @str = str
    @line = @line2 = 0
    @column = 0
    @coff = 0           # horizontal offset
    @off = @off2 = 0    # @off = first character of first line in cache
                        # @off = first character of first line past cache
    @cache = []
    @sizes = []
  end

  def debug
    [@line, @line2, @column, @coff, @off, @off2, "s", @sizes].flatten.join(" ")
  end

  # yield n lines with length len to be displayed
  def lines(n)
    @cache.each_with_index { |l, i|
      break if i >= n
      yield l
    }
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

  private
  def cache_forward(n)
    n.times do
      noff2 = @str.index("\n", @off2) or break
      nl = @str[@off2..(noff2-1)].split
      @sizes.max_update(nl.collect { |x| x.size })
      @cache << nl
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
      @cache.unshift(nl)
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
