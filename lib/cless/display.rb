class Array
  def max_update(a)
    a.each_with_index { |x, i|
      self[i] = x if !(v = self[i]) || v < x
    }
  end
end

class Attr
  NAME2COLORS = {
    "none" => -1,
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

  def on; Ncurses.attron(@attribute | @pair); end
  def off; Ncurses.attroff(@attribute | @pair); end

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
    Ncurses.use_default_colors
    Ncurses.init_pair(1, @foreground, @background)
    @pair = Ncurses.COLOR_PAIR(1)
  end
end

class Curses
  ((?a.ord)..(?z.ord)).each { |c|
    const_set("CTRL_#{c.chr.upcase}", c - ?a.ord + 1)
  }
  ESC = ?\e.ord
  SPACE = " "[0].ord # [0] useless for 1.9 but necessary for 1.8

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
    :line_highlight => true,   # Wether to hilight every other line
    :line_highlight_period => 2,
    :line_highlight_shift => 0,
    :col_highlight => true,    # Wether to hilight every other column
    :col_highlight_period => 2,
    :col_highlight_shift => 1,
    :column => false,           # Wether to display column number
    :col_start => 1,            # 1-based column numbering by default
    :line => false,             # Wether to display line number
    :line_offset => false,      # Display line offset instead of number
    :col_names => false,        # Wether to display column names
    :col_space => 1,            # Width of separator between columns
    :separator => " ",          # Separator caracter
    :padding => " ",            # Padding caracter
  }
  attr_accessor *DEFAULTS.keys
  attr_reader :prompt_line

  ISNUM = /^[+-]?\d*\.?\d*(?:[eE][+-]?\d+)?$/

  def separator=(s)
    @separator = (!s || s.empty?) ? " " : s
  end

  def padding=(s)
    @padding = (!s || s.empty?) ? " " : s
  end

  attr_accessor :col_headers
  def initialize(data, args = {})
    DEFAULTS.each { |k, v|
      self.send("#{k}=", args[k].nil? ? v : args[k])
    }
    @data = data
    @col_hide = []
    @align   = []       # column alignment: nil (i.e. auto), :left, :right, :center
    @col_headers = nil          # Actual names
    @col_off = @st_col = 0
    @args = args
  end

  def initialize_curses
    @attr = Attr.new(@args)
    @col_names &= @col_headers  # Disable col_names if no headers
    @args = nil
  end

  def nb_lines
    Ncurses.stdscr.getmaxy - 1 - (@column ? 1 : 0) - (@col_names ? 1 : 0)
  end

  def next_foreground; @attr.next_foreground; end
  def next_background; @attr.next_background; end
  def next_attribute; @attr.next_attribute; end
  def attr_names; @attr.names; end

  # @col_hide always store the 0 based indices of the
  # columns to show or hide. @col_start is taken into account when
  # setting and getting the @col_hide variables, and for display.
  def col_hide_clear; @col_hide = []; end
  def col_hide(*args)
    args = args.collect { |x| x - @col_start }
    @col_hide.push(*args)
    @col_hide.uniq!
    @col_hide.sort!
  end

  def col_hidden(with_start = true)
    if with_start
      @col_hide.collect { |x| x + @col_start }
    else
      @col_hide
    end
  end

  def col_show(*args) 
    @col_hide -= args.collect { |x| x - @col_start }
  end

  def col_align(align, cols)
    cols.each { |x|
      x -= @col_start
      next if x < 0
      @align[x] = align
    }
  end

  def st_col; @st_col; end

  def st_col=(n)
    n = 0 if n < 0
    n = @data.sizes.size if n > @data.sizes.size
    return @st_col if n == @st_col

    range, sign = (n > @st_col) ? [@st_col...n, 1] : [n...@st_col, -1]
    @col_off += sign * @data.sizes[range].inject(0) { |acc, x| 
      acc + x + @sep.size
    }
    @col_off = [@col_off, 0].max
    @col_off = 0 if n == 0
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
    line_i = @data.line + 1

    sline = refresh_column_headers

    @data.lines(lines) { |l|
      highlighted = @line_highlight && ((line_i - @line_highlight_shift) %
                                        @line_highlight_period == 0)
      highlighted ||= l.highlight?
      highlighted ? @attr.set : @attr.reset
      display_line(l, line_i, sline, highlighted)
      i += 1
      line_i += 1
      sline += 1
    }
    Ncurses.clrtobot
  ensure
    Ncurses.refresh
  end

  def display_line(l, line_i, sline, highlighted, sift = true)
    if @line
      Ncurses.attron(Ncurses::A_REVERSE) if l.has_match
      Ncurses.attron(Ncurses::A_UNDERLINE) if IgnoredLine === l
      s = @line_offset ? l.off : line_i
      Ncurses.mvaddstr(sline, 0, @col_fmt % [@linec, s])
      Ncurses.attroff(Ncurses::A_REVERSE) if l.has_match
      Ncurses.attroff(Ncurses::A_UNDERLINE) if IgnoredLine === l
    end

    if Line === l
      a = sift ? l.values_at(*@col_show) : l.values_at(0..-1)
#      if l.has_match || (@col_highlight && !highlighted)
#        # Lines has search matches or do column highlight
      # Now always display one field at a time
      ms = sift ? l.matches_at(*@col_show) : l.matches_at(0..-1)
      clen = @len
      @sizes.zip(ms).each_with_index { |sm, i|
        chilighted = !highlighted && @col_highlight
        chilighted &&= ((@st_col - @col_highlight_shift + i)%@col_highlight_period == 0)
        @attr.on if chilighted

        s, m = *sm
        align = @align[i]
        align = (a[i] =~ ISNUM) ? :right : :left if align.nil?

        if m 
           if align == :right
             Ncurses.addstr(str = (" " * (s - m.string.length))[0, clen])
             clen -= str.length; break if clen <= 0
           elsif align == :center
             Ncurses.addstr(str = (" " * ((s - m.string.length) / 2))[0, clen])
             clen -= str.length; break if clen <= 0
           end
          Ncurses.addstr(str = m.pre_match[0, clen])
          clen -= str.length; break if clen <= 0
          Ncurses.attron(Ncurses::A_REVERSE)
          Ncurses.addstr(str = m[0][0, clen])
          Ncurses.attroff(Ncurses::A_REVERSE)
          clen -= str.length; break if clen <= 0
          Ncurses.addstr(str = m.post_match[0, clen])
          clen -= str.length; break if clen <= 0
          if align == :left
            Ncurses.addstr(str = (" " * (s - m.string.length))[0, clen])
            clen -= str.length
          elsif align == :center
            space = s - m.string.length            
            Ncurses.addstr(str = (" " * (space / 2 + space % 2))[0, clen])
            clen -= str.length
          end
        else # No match
          case align
          when :left
            str = (a[i] || "").ljust(s)
          when :right
            str = (a[i] || "").rjust(s)
          when :center
            str = (a[i] || "").center(s)
          end
          Ncurses.addstr(str[0, clen])
          clen -= str.length; break if clen <= 0
        end
        @attr.off if chilighted
        Ncurses.addstr(str = @sep)
        clen -= str.length; break if clen <= 0            
      }
      @attr.reset if @col_highlight
      Ncurses.addstr(" " * clen) if clen > 0
      # else
      #   # No match, display all at once
      #   str = (@format % @sizes.zip(a).flatten).ljust(@len)[0, @len]
      #   Ncurses.addstr(str)
      # end
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

  # Modifies @sizes
  def refresh_column_headers
    @col_names &= @col_headers  # Disable col_names if no headers
    if @column
      cnumber = @col_show.map { |x| (x + @col_start).to_s }
      @sizes.max_update(cnumber.collect { |x| x.size })
    end
    if @col_names
      column_headers = @col_headers.values_at(*@col_show).map { |x| x || "" }
      hs = col_headers.map { |s| s.size }
      @sizes.max_update(hs)
    end

    sline = 0
    if @column
      Ncurses.attron(Ncurses::A_UNDERLINE) if !@col_names
      display_line(Line.new(cnumber), "", sline, false, false)
      Ncurses.attroff(Ncurses::A_UNDERLINE) if !@col_names
      sline += 1
    end
    if @col_names
      Ncurses.attron(Ncurses::A_UNDERLINE)
      display_line(Line.new(column_headers), "", sline, false, false)
      Ncurses.attroff(Ncurses::A_UNDERLINE)
      sline += 1
    end
    sline
  end

  def refresh_prepare
    lines = nb_lines
    @len = Ncurses.stdscr.getmaxx
    @col_show = (@st_col..(@st_col + @col_hide.size + @len / 2)).to_a
    @col_show -= @col_hide
    @sizes = @data.sizes.values_at(*@col_show).map { |x| x || 0 }
    if @line
      @linec = @line_offset ? @data.max_offset : (@data.line + lines)
      @linec = @linec.to_s.size
    end
    @len -= @linec + @col_space if @line
    @sep = @separator.center(@col_space, @padding)
    @col_fmt = "%*s#{@sep}"
    @format = @col_fmt * @col_show.size
    return lines
  end

  def wait_status(status, wprompt)
    len = Ncurses.stdscr.getmaxx
    Ncurses.attrset(Ncurses::A_NORMAL)
    Ncurses.mvaddstr(Ncurses.stdscr.getmaxy-1, 0, wprompt[0, len-1])
    
    nlen = len - wprompt.length
    Ncurses.attrset(Ncurses::A_BOLD)
    Ncurses.addstr(status.rjust(nlen)[0, nlen])
    Ncurses.attrset(Ncurses::A_NORMAL)
  end

  def flush
    Ncurses.refresh
  end

  def prompt(ps, opts = {})
    stdscr = Ncurses.stdscr
    len = stdscr.getmaxx
    Ncurses.attrset(Ncurses.COLOR_PAIR(0))
    Ncurses.mvaddstr(stdscr.getmaxy-1, 0, ps.ljust(len)[0, len])
    s, pos, key = read_line(stdscr.getmaxy-1, ps.length, opts)
    Ncurses.mvaddstr(stdscr.getmaxy-1, 0, " " * len)
    return (key == ?\e.ord) ? nil : s
  rescue KeyboardInterrupt
    return nil
  end

  # read_line returns an array
  # [string, last_cursor_position_in_string, keycode_of_terminating_enter_key].
  # options recognize:
  # :window     What window to work with
  # :max_len    Width of window
  # :string     Initial value
  # :cursor_pos Initial cursor position
  def read_line(y, x, opts = {})
    window       = opts[:window] || Ncurses.stdscr
    max_len      = opts[:max_len] || (window.getmaxx - x - 1)
    @prompt_line = opts[:init] || ""
    cursor_pos   = opts[:cursor_pos] || @prompt_line.size
    other        = opts[:other]
    extra        = opts[:extra]

    loop do
      window.mvaddstr(y,x,@prompt_line)
      window.move(y,x+cursor_pos)

      extra.call if extra

      ch = window.getch
      case ch
      when Ncurses::KEY_LEFT, Curses::CTRL_B
        cursor_pos = [0, cursor_pos-1].max
      when Ncurses::KEY_RIGHT, Curses::CTRL_F
        cursor_pos = [@prompt_line.length, cursor_pos+1].min
      when Ncurses::KEY_ENTER, ?\n.ord, ?\r.ord
        return @prompt_line, cursor_pos, ch # Which return key has been used?
      when Ncurses::KEY_HOME, Curses::CTRL_A
        cursor_pos = 0
      when Ncurses::KEY_END, Curses::CTRL_E
        cursor_pos = [max_len, @prompt_line.length].min
      when Ncurses::KEY_DC, Curses::CTRL_D
        @prompt_line.slice!(cursor_pos)
        window.mvaddstr(y, x+@prompt_line.length, " ")
      when Curses::CTRL_K
        window.mvaddstr(y, x+cursor_pos, " " * (@prompt_line.length - cursor_pos))
        @prompt_line = @prompt_line[0, cursor_pos]
      when Ncurses::KEY_BACKSPACE, ?\b.ord
        if cursor_pos > 0
          cursor_pos -= 1
          @prompt_line.slice!(cursor_pos)
          window.mvaddstr(y, x+@prompt_line.length, " ")
        else
          return "", 0, ?\e.ord
        end
      when ?\e.ord          # ESCAPE
        return "", 0, ch
      when C::SPACE..255 # remaining printables
        if (cursor_pos < max_len)
          @prompt_line[cursor_pos,0] = ch.chr
          cursor_pos += 1
        else
          Ncurses.beep
        end
      else
        other[ch] if other
      end
    end    	
  end 
end

class CommandSubWindow
  def initialize(width = 0, height = 15, bordery = 5, borderx = 10)
    maxy, maxx = Ncurses.stdscr.getmaxy, Ncurses.stdscr.getmaxx
    @nlines = [height + 2, maxy - 2 * bordery].min
    @ncols = [width + 2, maxx - 2 * borderx].min
    @win = Ncurses.stdscr.subwin(@nlines, @ncols, bordery, borderx)
    new_list([])
  end

  def destroy
    @win.delwin if @win
  end

  def new_list(list)
    @list = list
    @top_item = 0
    @cur_item = 0
    display_list
  end

  def display_list
    return unless @win
    @win.box(0, 0)
    len = @ncols - 2
    height = @nlines - 2
    str = " Commands "
    @win.mvaddstr(0, (len - str.size)  / 2, str) if len > str.size
    i = 1
    @list[@top_item..-1].each { |s|
      break if i > height
      @win.attron(Ncurses::A_REVERSE) if @cur_item + 1 == i + @top_item
      @win.mvaddstr(i, 1, s.ljust(len)[0, len])
      @win.attroff(Ncurses::A_REVERSE) if @cur_item + 1 == i + @top_item
      i += 1
    }
    empty = " " * len
    i.upto(height) { |j|
      @win.mvaddstr(j, 1, empty)
    }
    @win.wsyncup
  end

  def next_item
    @cur_item += 1 if @cur_item < @list.size - 1
    @top_item += 1 if (@cur_item - @top_item).abs >= @nlines - 2
    display_list
  end

  def previous_item
    @cur_item -= 1 if @cur_item > 0
    @top_item -= 1 if @cur_item < @top_item
    display_list
  end

  def item; @list[@cur_item]; end
end
