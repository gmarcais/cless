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

class Curses
  def initialize
    Ncurses.initscr
    @started = true
    Ncurses.start_color
    Ncurses.cbreak
    Ncurses.noecho
    Ncurses.nonl
    Ncurses.stdscr.intrflush(false)
    Ncurses.stdscr.immedok(false)
    Ncurses.keypad(Ncurses.stdscr, true)

    @basic_colors= [Ncurses::COLOR_BLACK, Ncurses::COLOR_RED, 
      Ncurses::COLOR_GREEN, Ncurses::COLOR_YELLOW, 
      Ncurses::COLOR_BLUE, Ncurses::COLOR_MAGENTA, Ncurses::COLOR_WHITE].sort

    # Create our pair, with same foreground as current but different background
    f, b = [], []
    Ncurses.pair_content(0, f, b)
    @basic_colors.each_with_index do |c, i|
      Ncurses.init_pair(i + 1, f[0], c)
    end
    @basic_colors.each_with_index do |c, i|
      Ncurses.init_pair(@basic_colors.size + i + 1, c, b[0])
    end

    begin
      yield self
    ensure
      @started && Ncurses.endwin
    end
  end

  def max_pair; 2*@basic_colors.size + 1; end

  def next_pair(i)
    i = (i+1) % max_pair
    i = 1 if i == 0
    i
  end
end

class Manager
  def initialize(data, display, curses)
    @data = data
    @display = display
    @curses = curses
    @done = false
    @status = ""
  end

  def done; @done = true; end

  def main_loop
    while !@done do
      @data.cache_fill(@display.nb_lines)
      @display.refresh
      @display.wait_status(@status)
      wait_for_key or break
    end
  end
  
  def wait_for_key
    status = nil
    while !@done do
      case k = Ncurses.getch
      when Ncurses::KEY_DOWN, Ncurses::KEY_ENTER, ?\n, ?\r: 
          @data.scroll(1); break
      when Ncurses::KEY_UP: @data.scroll(-1); break
      when " "[0], Ncurses::KEY_NPAGE: 
          @data.scroll(@display.nb_lines - 1); break
      when Ncurses::KEY_PPAGE: @data.scroll(1 - @display.nb_lines); break
      when Ncurses::KEY_HOME: @data.goto_start; break
      when Ncurses::KEY_END: @data.goto_end; break
      when Ncurses::KEY_LEFT: @display.st_col -= 1; break
      when Ncurses::KEY_RIGHT: @display.st_col += 1; break
      when Ncurses::KEY_F2
        @display.grey_color = @curses.next_pair(@display.grey_color)
        status = "New color: #{@display.grey_color}"
        break
      when ?g: @display.grey = !@display.grey; break
      when ?c: @display.column = !@display.column; break
      when ?l: @display.line = !@display.line; break
      when ?h: hide_columns; break
      when ?H: hide_columns(:show); break
      when Ncurses::KEY_RESIZE: break
      when ?q: return nil
      else 
      end
    end
    
    @status = status ? status : ""
    return true
  end

  def hide_columns(show = false)
    s = @display.prompt(show ? "Show: " : "Hide: ")
    a = s.split.collect { |x| x.to_i }
    if a[0] && a[0] <= 0
      @display.col_hide_clear
    else
      show ? @display.col_show(*a) : @display.col_hide(*a)
    end
  end
end

class LineDisplay
  DEFAULTS = {
    :grey => true,          # Wether to hilight every other line
    :grey_color => 1,
    :column => false,           # Wether to display column number
    :line => false,             # Wether to display line number
  }
  attr_accessor *DEFAULTS.keys

  attr_accessor :grey_color
  def initialize(data, args = {})
    DEFAULTS.each { |k, v|
      instance_variable_set("@#{k}", args[k].nil? ? v : args[k])
    }
    @data = data
    @col_hide = nil
    @st_col = 0
  end

  def nb_lines; Ncurses.stdscr.getmaxy - 1 - (@column ? 1 : 0); end

  def col_hide_clear; @col_hide = nil; end
  def col_hide(*args)
    args = args.collect { |x| x - 1 }
    @col_hide ||= []
    @col_hide.push(*args)
    @col_hide.uniq!
    @col_hide.sort!
  end
  
  def col_show(*args) 
    @col_hide and @col_hide -= args.collect { |x| x - 1 }
  end

  def st_col; @st_col; end

  def st_col=(n)
    return if n < 0
    @st_col = n
  end

  def refresh
    len = Ncurses.stdscr.getmaxx
    lines = Ncurses.stdscr.getmaxy - 1 - (@column ? 1 : 0)    
    sizes = @data.sizes.dup

    Ncurses.move(0, 0)
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    if @col_hide
      col_show = (0..(sizes.size-1)).to_a - @col_hide
    end
    if @column
      cheader = (1..sizes.size).to_a
      cheader = cheader.values_at(*col_show) if @col_hide
      cheader.slice!(0, @st_col)
      cheader.collect! { |x| x.to_s } 
    end
    sizes = sizes.values_at(*col_show) if @col_hide
    sizes.slice!(0, @st_col)
    sizes.unshift((@data.line + lines - 1).to_s.size) if @line
    format = "%*s " * sizes.size
    if @column
      sizes.max_update(cheader.collect { |x| x.size })
      cheader.unshift("") if @line
      i = -1
      cheader.collect! { |x| i += 1; x.center(sizes[i]) }
      s = (format % sizes.zip(cheader).flatten).ljust(len)[0, len]
      Ncurses.addstr(s)
    end

    i = 0
    sline = @column ? 1 : 0
    line_i = @data.line + 1
    @data.lines(lines) { |l|
      @grey and 
        Ncurses.attrset(Ncurses.COLOR_PAIR((line_i%2 == 0) ? 0 : @grey_color))
      a = @col_hide ? l.values_at(*col_show) : l.dup
      a.slice!(0, @st_col)
      a.unshift(line_i.to_s) if @line
      s = (format % sizes.zip(a).flatten).ljust(len)[0, len]
      Ncurses.mvaddstr(sline, 0, s)
      i += 1
      line_i += 1
      sline += 1
    }
    Ncurses.clrtobot
  ensure
    Ncurses.refresh
  end

  def wait_status(status)
    wprompt = ":"
    len = Ncurses.stdscr.getmaxx
    Ncurses.attrset(Ncurses::A_NORMAL)
    Ncurses.mvaddstr(Ncurses.stdscr.getmaxy-1, 0, wprompt)
    unless status.empty?
      Ncurses.attrset(Ncurses::A_BOLD)
      nlen = len - wprompt.length
      Ncurses.addstr(status.rjust(nlen)[0, nlen])
      Ncurses.attrset(Ncurses::A_NORMAL)
    end
  end

  def prompt(ps)
    stdscr = Ncurses.stdscr
    len = stdscr.getmaxx
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    Ncurses.mvaddstr(stdscr.getmaxy-1, 0, ps.ljust(len)[0, len])
    s = read_line(stdscr.getmaxy-1, ps.length)[0]
    Ncurses.mvaddstr(stdscr.getmaxy-1, 0, " " * len)
    s
  end

  # read_line returns an array
  # [string, last_cursor_position_in_string, keycode_of_terminating_enter_key].
  # Complete the "when" clauses before including in your app!
  def read_line(y, x,
                window     = Ncurses.stdscr,
                max_len    = (window.getmaxx - x - 1),
                string     = "",
                cursor_pos = 0)
    loop do
      window.mvaddstr(y,x,string)
      window.move(y,x+cursor_pos)
      ch = window.getch
      case ch
      when Ncurses::KEY_LEFT
        cursor_pos = [0, cursor_pos-1].max
      when Ncurses::KEY_RIGHT
        # similar, implement yourself !
      when Ncurses::KEY_ENTER, ?\n, ?\r
        return string, cursor_pos, ch # Which return key has been used?
      when Ncurses::KEY_BACKSPACE, ?\b
        string = string[0...([0, cursor_pos-1].max)] + string[cursor_pos..-1]
        cursor_pos = [0, cursor_pos-1].max
        window.mvaddstr(y, x+string.length, " ")
      when " "[0]..255 # remaining printables
        if (cursor_pos < max_len)
          string[cursor_pos,0] = ch.chr
          cursor_pos += 1
        else
          Ncurses.beep
        end
      else
      end
    end    	
    
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
    @line = nil

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
  def initialize(fname)
    @ptr = Mmap.new(fname)
    @line = nil

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

class MapData
  attr_reader :sizes, :line, :line2
  def initialize(str)
    @str = str
    @line = @line2 = 0
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

  def search(dir = :forward)
    
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
