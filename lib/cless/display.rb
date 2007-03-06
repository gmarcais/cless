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

class LineDisplay
  DEFAULTS = {
    :grey => true,          # Wether to hilight every other line
    :grey_color => 1,
    :column => false,           # Wether to display column number
    :col_zero => false,         # 0-based column numbering
    :line => false,             # Wether to display line number
    :line_offset => false,      # Display line offset instead of number
    :col_names => false,        # Wether to display column names
    :col_space => 1,            # Number of spaces between columns
  }
  attr_accessor *DEFAULTS.keys

  attr_accessor :grey_color, :col_headers
  def initialize(data, args = {})
    DEFAULTS.each { |k, v|
      self.send("#{k}=", args[k].nil? ? v : args[k])
    }
    @data = data
    @col_hide = nil
    @col_headers = nil          # Actual names
    @st_col = 0
    @attr = Attr.new(args)
  end

  def nb_lines
    Ncurses.stdscr.getmaxy - 1 - (@column ? 1 : 0) - (@col_names ? 1 : 0)
  end

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
    return @st_col if n < 0 || n > @data.sizes.size
    @st_col = n
  end

  def col_space=(n)
    @col_space = [1, n.to_i].max
  end

  def refresh
    Ncurses.move(0, 0)
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    lines = refresh_prepare

    i = 0
    sline = 0 + (@column ? 1 : 0) + (@col_names ? 1 : 0)
    line_i = @data.line + 1

    refresh_column_headers

    @data.lines(lines) { |l|
      @grey and ((line_i%2 == 0) ? @attr.reset : @attr.set)
      display_line(l, line_i, sline)
      i += 1
      line_i += 1
      sline += 1
    }
    Ncurses.clrtobot
  ensure
    Ncurses.refresh
  end

  def display_line(l, line_i, sline)
    if @line
      Ncurses.attron(Ncurses::A_REVERSE) if l.has_match
      Ncurses.attron(Ncurses::A_UNDERLINE) if IgnoredLine === l
      s = @line_offset ? l.off : line_i
      Ncurses.mvaddstr(sline, 0, @col_fmt % [@linec, s])
      Ncurses.attroff(Ncurses::A_REVERSE) if l.has_match
      Ncurses.attroff(Ncurses::A_UNDERLINE) if IgnoredLine === l
    end
    space = " " * @col_space
    if Line === l
      a = l.values_at(*@col_show)
      a.slice!(0, @st_col)
      if l.has_match
        # Lines has search matches, display a field at a time
        ms = l.matches_at(*@col_show)
        ms.slice!(0, @st_col)
        clen = @len
        @sizes.zip(ms).each_with_index { |sm, i|
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
            Ncurses.addstr(str = space)
            clen -= str.length; break if clen <= 0            
          else
            Ncurses.addstr(str = (@col_fmt % [s, a[i]])[0, clen])
            clen -= str.length; break if clen <= 0
          end
        }
        Ncurses.addstr(" " * clen) if clen > 0
      else
        # No match, display all at once
        str = (@format % @sizes.zip(a).flatten).ljust(@len)[0, @len]
        Ncurses.addstr(str)
      end
    else # l is an ignored line
      off = @col_off
      clen = @len
      if l.has_match
        m = l.matches
        s = m.pre_match
        if s.length > off && clen > 0
          Ncurses.addstr(str = s[off, clen])
          clen -= str.length
          off = 0
        else
          off -= s.length
        end
        s = m[0]
        if s.length > off && clen > 0
          Ncurses.attron(Ncurses::A_REVERSE)
          Ncurses.addstr(str = s[off, clen])
          Ncurses.attroff(Ncurses::A_REVERSE)
          clen -= str.length
          off = 0
        else
          off -= s.length
        end
        s = m.post_match
        if s.length > off && clen > 0
          Ncurses.addstr(str = s[off, clen])
          clen -= str.length
        end
        Ncurses.addstr(" " * clen) if clen > 0
      else
        s = l.str
        if s.length > off && clen > 0
          Ncurses.addstr(str = s[off, @len].ljust(clen)[0, clen])
          clen -= str.length
        end
        Ncurses.addstr(" " * clen) if clen > 0
      end
    end
  end

  # Modifies sizes
  # linec: size of line number column
  # Return byte column offset
  def refresh_column_headers
    if @column
      inc = (@col_zero) ? 0 : 1
      cnumber = @col_show.collect { |x| (x + inc).to_s }
      cnumber.compact!
      @sizes.max_update(cnumber.collect { |x| x.size })
      cnumber.slice!(0, @st_col)
    end
    if @col_names
      cnames = @col_headers.values_at(*@col_show)
      cnames.compact!
      @sizes.max_update(cnames.collect { |s| s.size })
      cnames.slice!(0, @st_col)
    end

    @col_off = @sizes[0...@st_col].inject(0) { |a, x| a + x } + @st_col
    @sizes.slice!(0, @st_col)

    if @column
      Ncurses.addstr(" " * (@linec + @col_space)) if @line
      i = -1
      cnumber.collect! { |x| i += 1; x.center(@sizes[i]) }
      s = (@format % @sizes.zip(cnumber).flatten).ljust(@len)[0, @len]
      Ncurses.addstr(s)
    end
    if @col_names
      Ncurses.addstr(" " * (@linec + 1)) if @line
      i = -1
      cnames.collect! { |x| i += 1; x.center(@sizes[i]) }
      s = (@format % @sizes.zip(cnames).flatten).ljust(@len)[0, @len]
      Ncurses.addstr(s)
    end
  end

  def refresh_prepare
    lines = nb_lines
    @len = Ncurses.stdscr.getmaxx
    @sizes = @data.sizes.dup
    @col_show = (0..(@sizes.size-1)).to_a
    @col_show -= @col_hide if @col_hide
    @sizes = @sizes.values_at(*@col_show)
    if @line
      @linec = @line_offset ? @data.max_offset : (@data.line + lines)
      @linec = @linec.to_s.size
    end
    @len -= @linec + @col_space if @line
    nbf = [@sizes.size - @st_col, 0].max
    @col_fmt = "%*s#{' ' * @col_space}"
    @format = @col_fmt * nbf
    return lines
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
  rescue KeyboardInterrupt
    return nil
  end

  # read_line returns an array
  # [string, last_cursor_position_in_string, keycode_of_terminating_enter_key].
  CTRL_A = ?a - ?a + 1
  CTRL_B = ?b - ?a + 1
  CTRL_D = ?d - ?a + 1
  CTRL_E = ?e - ?a + 1
  CTRL_F = ?f - ?a + 1
  CTRL_H = ?h - ?a + 1
  CTRL_K = ?k - ?a + 1
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
      when Ncurses::KEY_LEFT, CTRL_B
        cursor_pos = [0, cursor_pos-1].max
      when Ncurses::KEY_RIGHT, CTRL_F
        cursor_pos = [string.length, cursor_pos+1].min
      when Ncurses::KEY_ENTER, ?\n, ?\r
        return string, cursor_pos, ch # Which return key has been used?
      when Ncurses::KEY_HOME, CTRL_A
        cursor_pos = 0
      when Ncurses::KEY_END, CTRL_E
        cursor_pos = [max_len, string.length].min
      when Ncurses::KEY_DC, CTRL_D
        string.slice!(cursor_pos)
        window.mvaddstr(y, x+string.length, " ")
      when CTRL_K
        window.mvaddstr(y, x, " " * string.length)
        string = ""
      when Ncurses::KEY_BACKSPACE, ?\b
        if cursor_pos > 0
          cursor_pos -= 1
          string.slice!(cursor_pos)
          window.mvaddstr(y, x+string.length, " ")
        end
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
