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

class Attr
  NAME2COLORS = {
    "none" => :none,
    "black" => Ncurses::COLOR_BLACK,
    "red" =>  Ncurses::COLOR_RED,
    "green" => Ncurses::COLOR_GREEN,
    "yellow" =>  Ncurses::COLOR_YELLOW,
    "blue" =>  Ncurses::COLOR_BLUE,
    "magenta" => Ncurses::COLOR_MAGENTA,
    "white" => Ncurses::COLOR_WHITE,
  }
  COLORS = NAME2COLORS.values
  NAME2ATTR = {
    "normal" => Ncurses::A_NORMAL,
    "standout" => Ncurses::A_STANDOUT,
    "underline" => Ncurses::A_UNDERLINE,
    "dim" => Ncurses::A_DIM,
    "bold" => Ncurses::A_BOLD,
  }
  ATTRS = NAME2ATTR.values

  DEFAULTS = {
    :background => NAME2COLORS["none"],
    :foreground => NAME2COLORS["none"],
    :attribute => NAME2ATTR["bold"],
  }

  def initialize(args = {})       # background, foreground, attribute
    # Sanitize
    DEFAULTS.each { |k, v|
      instance_variable_set("@#{k}", args[k].nil? ? v : args[k])
    }
    @background = check_color(@background)
    @foreground = check_color(@foreground)
    @attribute = check_attribute(@attribute)
    update_pair
  end

  def next_background; @background = inc(@background, COLORS); update_pair; end
  def next_foreground; @foreground = inc(@foreground, COLORS); update_pair; end
  def next_attribute; @attribute = inc(@attribute, ATTRS); end

  def set; Ncurses.attrset(@attribute | @pair); end
  def reset; Ncurses.attrset(Ncurses::A_NORMAL); end

  def names
    r = {}
    r[:foreground] = (NAME2COLORS.find { |n, v| v == @foreground } || ["black"])[0]
    r[:background] = (NAME2COLORS.find { |n, v| v == @background } || ["white"])[0]
    r[:attribute] = (NAME2ATTR.find { |n, v| v == @attribute } || ["normal"])[0]
    r
  end

  private
  def check(c, hash, ary)
    case c
    when Integer
      ary.include?(c) ? c : ary.first
    when String
      (v = hash[c.downcase.strip]) ? v : ary.first
    else
      ary.first
    end
  end
  def check_color(c); check(c, NAME2COLORS, COLORS); end
  def check_attribute(a); check(a, NAME2ATTR, ATTRS); end

  def inc(c, ary); ary[((ary.index(c) || 0)+1) % ary.size]; end

  def update_pair
    if @foreground != :none && @background != :none
      Ncurses.init_pair(1, @foreground, @background)
      @pair = Ncurses.COLOR_PAIR(1)
    else
      @pair = 0
    end
  end
end

class Curses
  def initialize(args = {})
    Ncurses.initscr
    @started = true
    begin
      Ncurses.start_color
      Ncurses.cbreak
      Ncurses.noecho
      Ncurses.nonl
      Ncurses.stdscr.intrflush(false)
      Ncurses.stdscr.immedok(false)
      Ncurses.keypad(Ncurses.stdscr, true)


      yield self
    ensure
      @started && Ncurses.endwin
    end
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
      when ?g: @display.grey = !@display.grey; break
      when ?c: @display.column = !@display.column; break
      when ?l: @display.line = !@display.line; break
      when ?h: status = hide_columns; break
      when ?H: status = hide_columns(:show); break
      when ?0: @display.col_zero = !@display.col_zero; break
      when ?1: @display.next_foreground; status = color_descr; break
      when ?2: @display.next_background; status = color_descr; break
      when ?3: @display.next_attribute; status = color_descr; break
      when ?/: status = search(:forward); break
      when ??: status = search(:backward); break
      when ?n: status = repeat_search(:forward); break
      when ?p: status = repeat_search(:backward); break
      when Ncurses::KEY_RESIZE: break
      when ?q: return nil
      else 
      end
    end
    
    @status = status ? status : ""
    return true
  end

  def hide_columns(show = false)
    s = @display.prompt(show ? "Show: " : "Hide: ") or return "Canceled"
    a = s.split.collect { |x| x.to_i }
    if a.empty?
      @display.col_hide_clear
    else
      show ? @display.col_show(*a) : @display.col_hide(*a)
    end
    "Hidden: #{@display.col_hidden.join(" ")}"
  end

  # Return a status if an error occur, otherwise, returns nil
  def search(dir = :forward)
    s = @display.prompt("%s Search: " % 
                          [(dir == :forward) ? "Forward" : "Backward"])
    s or return "Canceled"
    if s =~ /^\s*$/
      @data.search_clear
    else
      begin
        pattern = Regexp.new(s)
        @data.search(pattern) or return "Pattern not found!"
      rescue RegexpError => e
        return "Bad regexp: #{e.message}"
      end
    end
    nil
  end

  # Return a status if an error occur, otherwise, returns nil
  def repeat_search(dir = :forward)
    return "No pattern" if !@data.pattern
    @data.repeat_search(dir) or return "Pattern not found!"
    return nil
  end

  def color_descr
    descr = @display.attr_names
    "Color: F %s B %s A %s" % 
      [descr[:foreground] || "-", descr[:background] || "-", descr[:attribute] || "-"]
  end
end

class LineDisplay
  DEFAULTS = {
    :grey => true,          # Wether to hilight every other line
    :grey_color => 1,
    :column => false,           # Wether to display column number
    :col_zero => false,         # 0-based column numbering
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
    @attr = Attr.new(args)
  end

  def nb_lines; Ncurses.stdscr.getmaxy - 1 - (@column ? 1 : 0); end

  def next_foreground; @attr.next_foreground; end
  def next_background; @attr.next_background; end
  def next_attribute; @attr.next_attribute; end
  def attr_names; @attr.names; end

  # col_hide and col_show respect the flag col_zero. I.e. the index of the
  # column to pass is 0-based or 1-based depending on col_zero
  def col_hide_clear; @col_hide = nil; end
  def col_hide(*args)
    inc = @col_zero ? 0 : 1
    args = args.collect { |x| x - inc }
    @col_hide ||= []
    @col_hide.push(*args)
    @col_hide.uniq!
    @col_hide.sort!
  end

  def col_hidden
    return [] unless @col_hide
    @col_zero ? @col_hide : @col_hide.collect { |x| x + 1 }
  end

  def col_show(*args) 
    inc = @col_zero ? 0 : 1
    @col_hide and @col_hide -= args.collect { |x| x - inc }
  end

  def st_col; @st_col; end

  def st_col=(n)
    return if n < 0
    @st_col = n
  end

  def refresh
    Ncurses.move(0, 0)
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    col_show, sizes, len, lines, linec, format = refresh_prepare

    i = 0
    sline = @column ? 1 : 0
    line_i = @data.line + 1
    refresh_column_headers(sizes, format, col_show, len, linec) if @column

    @data.lines(lines) { |l|
      @grey and ((line_i%2 == 0) ? @attr.reset : @attr.set)
      a = l.values_at(*col_show)
      a.slice!(0, @st_col)
      if @line
        Ncurses.attron(Ncurses::A_REVERSE) if l.has_match
        Ncurses.mvaddstr(sline, 0, "%*s " % [linec, line_i])
        Ncurses.attroff(Ncurses::A_REVERSE) if l.has_match
      end
      if l.has_match
        # Lines has search matches, display a field at a time
        ms = l.matches_at(*col_show)
        ms.slice!(0, @st_col)
        clen = len
        sizes.zip(ms).each_with_index { |sm, i|
          s, m = *sm
          if m
            Ncurses.addstr(str = (" " * (s - m.string.length))[0, clen])
            clen -= str.length; break if clen <= 0
            Ncurses.addstr(str = m.pre_match[0, clen])
            clen -= str.length; break if clen <= 0
            Ncurses.attron(Ncurses::A_REVERSE)
            Ncurses.addstr(str = m[0][0, clen])
            Ncurses.attroff(Ncurses::A_REVERSE)
            clen -= str.length; break if clen <= 0
            Ncurses.addstr(str = m.post_match[0, clen])
            clen -= str.length; break if clen <= 0
            Ncurses.addstr(str = " ")
            clen -= str.length; break if clen <= 0            
          else
            Ncurses.addstr(str = ("%*s " % [s, a[i]])[0, clen])
            clen -= str.length; break if clen <= 0
          end
        }
        Ncurses.addstr(" " * clen) if clen > 0
      else
        # No match, display all at once
        str = (format % sizes.zip(a).flatten).ljust(len)[0, len]
        Ncurses.addstr(str)
      end
      i += 1
      line_i += 1
      sline += 1
    }
    Ncurses.clrtobot
  ensure
    Ncurses.refresh
  end

  # Modifies sizes
  # linec: size of line number column
  def refresh_column_headers(sizes, format, col_show, len, linec)
    inc = (@col_zero) ? 0 : 1
    cheader = col_show.slice((@st_col)..-1).collect { |x| (x + inc).to_s }
    sizes.max_update(cheader.collect { |x| x.size })
    Ncurses.addstr(" " * (linec + 1)) if @line
    i = -1
    cheader.collect! { |x| i += 1; x.center(sizes[i]) }
    s = (format % sizes.zip(cheader).flatten).ljust(len)[0, len]
    Ncurses.addstr(s)
  end

  def refresh_prepare
    lines = nb_lines
    len = Ncurses.stdscr.getmaxx
    sizes = @data.sizes.dup
    col_show = (0..(sizes.size-1)).to_a
    col_show -= @col_hide if @col_hide
    sizes = sizes.values_at(*col_show)
    sizes.slice!(0, @st_col)
    linec = (@data.line + lines).to_s.size if @line
    len -= linec + 1 if @line
    format = "%*s " * sizes.size

    return col_show, sizes, len, lines, linec, format
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
    s, pos, key = read_line(stdscr.getmaxy-1, ps.length)
    Ncurses.mvaddstr(stdscr.getmaxy-1, 0, " " * len)
    return (key == ?\e) ? nil : s
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
        cursor_pos = [string.length, cursor_pos+1].min
      when Ncurses::KEY_ENTER, ?\n, ?\r
        return string, cursor_pos, ch # Which return key has been used?
      when Ncurses::KEY_HOME
        cursor_pos = 0
      when Ncurses::KEY_END
        cursor_pos = [max_len, string.length].min
      when Ncurses::KEY_BACKSPACE, ?\b
        string = string[0...([0, cursor_pos-1].max)] + string[cursor_pos..-1]
        cursor_pos = [0, cursor_pos-1].max
        window.mvaddstr(y, x+string.length, " ")
      when ?\e          # ESCAPE
        return "", 0, ch
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
