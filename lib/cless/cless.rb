require 'ncurses'
require 'mmap'
require 'tempfile'

require 'cless/data'
require 'cless/display'
require 'cless/optionsdb'
require 'cless/export'
require 'cless/help'

class String
  def split_with_quotes(sep = '\s', q = '\'"')
    r = / \G(?:^|[#{sep}])     # anchor the match
           (?: [#{q}]((?>[^#{q}]*)(?>""[^#{q}]*)*)[#{q}] # find quoted fields
               |                                  # ... or ...
              ([^#{q}#{sep}]*)  # unquoted fields
             )/x
    self.split(r).delete_if { |x| x.empty? }
  end
end

class Interrupt
  def initialize; @raised = false; end
  def raise; @raised = true; end
  def reset; r, @raised = @raised, false; r; end
end

class Manager
  class Error < StandardError; end

  Commands = {
    "scroll_forward_line" => :scroll_forward_line,
    "scroll_backward_line" => :scroll_backward_line,
    "scroll_forward_half_screen" => :scroll_forward_half_screen,
    "scroll_backward_half_screen" => :scroll_backward_half_screen,
    "scroll_right" => :scroll_right,
    "scroll_left" => :scroll_left,
    "hide_columns" => :hide_columns_prompt,
    "unhide_columns" => :unhide_columns,
    "toggle_headers" => :show_hide_headers,
    "change_headers_to_line" => :change_headers_to_line_content_prompt,
    "toggle_line_highlight" => :toggle_line_highlight,
    "toggle_column_highlight" => :toggle_column_highlight,
    "shift_line_highlight" => :shift_line_highlight,
    "shift_column_highlight" => :shift_column_highlight,
    "regexp_line_highlight" => :regexp_line_highlight_prompt,
    "forward_search" => :forward_search,
    "backward_search" => :backward_search,
    "repeat_search" => :repeat_search,
    "save_to_file" => :save_file_prompt,
    "goto_position" => :goto_position_prompt,
    "format_column" => :column_format_prompt,
    "column_start_index" => :change_column_start_prompt,
    "ignore_line" => :ignore_line_prompt,
    "remove_ignore_line" => :ignore_line_remove_prompt,
    "split_regexp" => :change_split_pattern_prompt,
    "separator_character" => :change_separator_prompt,
    "separator_padding" => :change_padding_prompt,
    "export" => :export_prompt,
    "help" => :display_help,
  }

  def initialize(data, display, db)
    @data = data
    @display = display
    @db = db
    @done = false
    @status = ""
    @prebuff = ""
    @half_screen_lines = nil
    @full_screen_lines = nil
    @scroll_columns = nil
    @interrupt = false
  end

  def done; @done = true; end
  def interrupt_set; @interrupt = true; end
  def interrupt_reset; i, @interrupt = @interrupt, false; i; end

  def main_loop
    if @status.empty?
      @status = "Help? Press a or F1"
    end
    while !@done do
      @data.cache_fill(@display.nb_lines)
      @display.refresh
      wait_for_key or break
    end
  end

  def prebuff; @prebuff.empty? ? nil : @prebuff.to_i; end
  
  def wait_for_key
    status = nil
    esc = false
    while !@done do
      nc = false        # Set to true if no data change
      data_fd = @data.select_fd
      prompt = data_fd ? "+:" : ":"
      @display.wait_status(@status, prompt + @prebuff)
      if data_fd
        @display.flush
        in_fds = [$stdin, data_fd]
        in_fds = select(in_fds)
        if in_fds[0].include?(data_fd)
          status = :more
          nc = true
          break
        end
      end

      status = 
        case k = Ncurses.getch
        when Ncurses::KEY_DOWN, Ncurses::KEY_ENTER, Curses::CTRL_N, ?e, Curses::CTRL_E, ?j, ?\n, ?\r
          scroll_forward_line
        when Ncurses::KEY_UP, ?y, Curses::CTRL_Y, Curses::CTRL_P, ?k, Curses::CTRL_K
          scroll_backward_line
        when ?d, Curses::CTRL_D
          scroll_forward_half_screen(true)
        when ?u, Curses::CTRL_U
          scroll_backward_half_screen(true)
        when " "[0], Ncurses::KEY_NPAGE, Curses::CTRL_V, ?f, Curses::CTRL_F
          scroll_forward_full_screen
        when ?z: scroll_forward_full_screen(true)
        when Ncurses::KEY_PPAGE, ?b, Curses::CTRL_B
          scroll_backward_full_screen
        when ?w
          scroll_backward_full_screen(true)
        when Ncurses::KEY_HOME, ?g, ?<: goto_line(0)
        when Ncurses::KEY_END, ?G, ?>: goto_line(-1)
        when Ncurses::KEY_LEFT: scroll_left
        when Ncurses::KEY_RIGHT: scroll_right
        when ?+: @display.col_space += 1; true
        when ?-: @display.col_space -= 1; true
        when ?F: goto_position_prompt
        when ?v: column_format_prompt
        when ?i: ignore_line_prompt
        when ?I: ignore_line_remove_prompt
        when ?o: toggle_line_highlight
        when ?O: toggle_column_highlight
        when ?m: shift_line_highlight
        when ?M: shift_column_highlight
        when ?c: @display.column = !@display.column; true
        when ?l: @display.line = !@display.line; true
        when ?L: @display.line_offset = !@display.line_offset; true
        when ?h: hide_columns_prompt
        when ?H: hide_columns_prompt(:show)
        when ?): esc ? scroll_right : change_column_start_prompt
        when ?(: esc ? scroll_left : true
        when ?/: search_prompt(:forward)
        when ??: search_prompt(:backward)
        when ?n: repeat_search
        when ?N: repeat_search(true)
        when ?s: save_file_prompt
        when ?S: change_split_pattern_prompt
        when ?E: export_prompt
        when ?t: show_hide_headers
        when ?p, ?%: goto_percent
        when ?x: change_separator_prompt
        when ?X: change_padding_prompt
        when ?^: change_headers_to_line_content_prompt
        when ?r, ?R, Curses::CTRL_R, Curses::CTRL_L
          @data.clear_cache; Ncurses::endwin; Ncurses::doupdate
        when Ncurses::KEY_RESIZE: nc = true # Will break to refresh display
        when Ncurses::KEY_F1, ?a: display_help
        when ?0..?9: @prebuff += k.chr; next
        when Ncurses::KEY_BACKSPACE, ?\b
          esc ? @prebuff = "" : @prebuff.chop!; next
        when ?:: long_command
        when ?q: return nil
        when Curses::ESC: esc = true; next
        else 
          next
        end
      break
    end
    
    @prebuff = "" unless nc
    @status = 
      case status
      when String: status
      when nil: "Cancelled"
      when :more: @status
      else
        ""
      end
    return true
  end

  # This is a little odd. Does it belong to display more?
  def long_command
    sub = CommandSubWindow.new(Commands.keys.map { |s| s.size }.max)
    old_prompt_line = ""
    sub.new_list(Commands.keys.sort)
    extra = proc {
      if old_prompt_line != @display.prompt_line
        old_prompt_line = @display.prompt_line.dup
        reg = Regexp.new(Regexp.quote(old_prompt_line))
        sub.new_list(Commands.keys.grep(reg).sort)
        Ncurses.refresh
      end
    }
    other = proc { |ch|
      r = true
      case ch
      when Ncurses::KEY_DOWN, Curses::CTRL_N: sub.next_item
      when Ncurses::KEY_UP, Curses::CTRL_P: sub.previous_item
      else
        r = false
      end
      Ncurses.refresh if r
    }
    s = @display.prompt("Filter: ", :extra => extra, :other => other)
    sub.destroy
    @display.refresh
    self.__send__(Commands[sub.item]) if s
  end

  def scroll_forward_line
    @data.scroll(prebuff || 1)
    true
  end

  def scroll_backward_line
    @data.scroll(-(prebuff || 1))
    true
  end

  def scroll_forward_half_screen(save = false)
    @half_screen_lines = prebuff if save && prebuff
    @data.scroll(prebuff || @half_screen_lines || (@display.nb_lines / 2))
    true
  end

  def scroll_backward_half_screen(save = false)
    @half_screen_lines = prebuff if save && prebuff
    @data.scroll(-(prebuff || @half_screen_lines || (@display.nb_lines / 2)))
    true
  end

  def scroll_forward_full_screen(save = false)
    @full_screen_lines = prebuff if save && prebuff
    @data.scroll(prebuff || @full_screen_lines || (@display.nb_lines - 1))
    true
  end

  def scroll_backward_full_screen(save = false)
    @full_screen_lines = prebuff if save && prebuff
    @data.scroll(-(prebuff || @full_screen_lines || (@display.nb_lines - 1)))
    true
  end

  def scroll_right
    @scroll_columns = prebuff if prebuff
    @display.st_col += @scroll_columns || 1
    true
  end

  def scroll_left
    @scroll_columns = prebuff if prebuff
    @display.st_col += -(@scroll_columns || 1)
    true
  end

  def goto_line(l)
    if prebuff
      @data.goto_line(prebuff)
    else
      (l < 0) ? @data.goto_end : @data.goto_start
    end
    true
  end

  def unhide_columns; hide_columns_prompt(true); end
  def hide_columns_prompt(show = false)
    i = prebuff
    if i
      a = [i]
    else
      s = @display.prompt(show ? "Show: " : "Hide: ") or return nil
      a = s.split.collect { |x| x.to_i }
    end
    if a.empty?
      @display.col_hide_clear
    else
      show ? @display.col_show(*a) : @display.col_hide(*a)
    end
    "Hidden: #{@display.col_hidden.join(" ")}"
  end

  def show_hide_headers
    return "No names defined" if !@display.col_names && !@display.col_headers
    @display.col_names = !@display.col_names
    true
  end

  def change_headers_to_line_content_prompt
    i = prebuff
    if i.nil?
      i = @data.line + 1
      s = @display.prompt("Header line: ", :init => i.to_s) or return nil
      s.strip!
      return "Bad line number #{s}" unless s =~ /^\d+$/
      i = s.to_i
    end
    begin
      change_headers_to_line(i)
    rescue => e
      return e.message
    end
    true
  end

  def toggle_line_highlight
    i = prebuff
    @display.line_highlight = !@display.line_highlight
    @display.line_highlight_period = i if i
    true
  end

  def toggle_column_highlight
    i = prebuff
    @display.col_highlight = !@display.col_highlight
    @display.col_highlight_period = i if i
    true
  end

  def shift_line_highlight
    if i = prebuff
      @display.line_highlight_shift = i
    else
      @display.line_highlight_shift += 1
    end
  end
  
  def shift_column_highlight
    if i = prebuff
      @display.col_highlight_shift = i
    else
      @display.col_highlight_shift += 1
    end
  end
  
  def change_headers_to_line(i)
    raise Error, "Bad line number #{i}" if i < 1
    i_bak = @data.line + 1
    @data.goto_line(i)
    @data.cache_fill(1)
    line = nil
    @data.lines(1) { |l| line = l }
    @data.goto_line(i_bak)     # Go back
    raise Error, "No such line" unless line
    raise Error, "Ignored line: can't use" if line.kind_of?(IgnoredLine)
    @display.col_headers = line.onl_at(0..-1)
    @display.col_names = true
    true
  end

  # Return a status if an error occur, otherwise, returns nil
  def forward_search; search_prompt(:forward); end
  def backward_search; search_prompt(:backward); end
  def search_prompt(dir = :forward)
    s = @display.prompt("%s Search: " % 
                          [(dir == :forward) ? "Forward" : "Backward"])
    s or return nil
    if s =~ /^\s*$/
      @data.search_clear
    else
      begin
        @search_dir = dir
        pattern = Regexp.new(s)
        @data.search(pattern, dir) or return "Pattern not found!"
      rescue RegexpError => e
        return "Bad regexp: #{e.message}"
      end
    end
    true
  end

  # Return a status if an error occur, otherwise, returns nil
  def repeat_search(reverse = false)
    return "No pattern" if !@data.pattern
    dir = if reverse 
            (@search_dir == :forward) ? :backward : :forward
          else 
            @search_dir
          end
    @data.repeat_search(dir) or return "Pattern not found!"
    true
  end

  def color_descr
    descr = @display.attr_names
    "Color: F %s B %s A %s" % 
      [descr[:foreground] || "-", descr[:background] || "-", descr[:attribute] || "-"]
  end

  def save_file_prompt
    s = @display.prompt("Save to: ")
    return nil if !s || s.empty?
    begin
      File.link(@data.file_path, s)
      return "Hard linked"
    rescue Errno::EXDEV => e
    rescue Exception => e
      return "Error: #{e.message}"
    end

    # Got here, hard link failed. Copy by hand.
    nb_bytes = nil
    begin
      File.open(s, File::WRONLY|File::CREAT|File::EXCL) do |fd|
        nb_bytes = @data.write_to(fd)
      end
    rescue Exception => e
      return "Error: #{e.message}"
    end
    "Wrote #{nb_bytes} bytes"
  end

  def goto_percent
    percent = prebuff or return true
    @data.goto_percent(percent)
  end

  def goto_position_prompt
    s = @display.prompt("Goto: ") or return nil
    s.strip!
    case s[-1]
    when ?p, ?%
      s.slice!(-1)
      f = s.to_f
      return "Invalid percentage" if f <= 0.0 || f > 100.0
      @data.goto_percent(f)
    when ?o
      s.slice!(-1)
      i = s.to_i
      return "Invalid offset" if i < 0
      @data.goto_offset(i)
    else
      i = s.to_i
      return "Invalid line number" if i <= 0
      @data.goto_line(i)
    end
    true
  end

  def column_format_prompt
    s = @display.prompt("Format: ") or return nil
    s.strip!
    column_format(s)
  end
  
  def column_format(s)
    cols, fmt = s.split(/:/, 2)
    inc = @display.col_start
    if cols
      cols = cols.split.collect { |x| x.to_i - inc }
      cols.delete_if { |x| x < 0 }
      if fmt && !fmt.empty?
        @data.set_format_column(fmt, *cols)
      else
        cols.each { |c| @data.unset_format_column(c) }
      end
      @data.refresh
    end
    cols = @data.formatted_column_list.sort.collect { |x| x + inc }
    "Formatted: " + cols.join(" ")
  end

  def change_column_start_prompt
    s = prebuff
    s = @display.prompt("First column: ") unless s
    return nil unless s
    @display.col_start = s.to_i
    true
  end

  def ignore_line_prompt
    s = @display.prompt("Ignore: ") or return nil
    s.strip!
    ignore_line(s)
  end

  def ignore_line_list_each(str)
    a = str.split_with_quotes('\s', '\/')
    a.each do |spat|
      opat = case spat
             when /^(\d+)(?:\.{2}|-)(\d+)$/: ($1.to_i - 1)..($2.to_i - 1)
             when /^(\d+)$/: $1.to_i - 1
             else Regexp.new(spat) rescue nil
             end
      yield(spat, opat)
    end
  end

  def ignore_line_list_display(a)
    a.collect { |x|
      o = case x
          when Range: (x.begin + 1)..(x.end + 1)
          when Fixnum: x + 1
          else x
          end
      o.inspect
    }
  end

  def ignore_line(str)
    ignore_line_list_each(str) do |spat, opat|
      if opat.nil? || !@data.add_ignore(opat)
        return "Bad pattern #{spat}"
      end
    end
    @data.refresh
    "Ignored: " + ignore_line_list_display(@data.ignore_pattern_list).join(" ")
  end

  def ignore_line_remove_prompt
    s = @display.prompt("Remove ignore: ") or return nil
    s.strip!
    ignore_line_remove(s)
  end

  def ignore_line_remove(str)
    if !str || str.empty?
      @data.remove_ignore(nil)
    else
      ignore_line_list_each(str) do |spat, opat|
        opat && @data.remove_ignore(opat)
      end
    end
    @data.refresh
    "Ignored: " + ignore_line_list_display(@data.ignore_pattern_list).join(" ")
  end

  def change_split_pattern_prompt
    s = @display.prompt("Split regexp(/#{@data.split_regexp}/): ")
    return "Not changed" if !s
    begin
      s.gsub!(%r{^/|/$}, '')
      regexp = s.empty? ? nil : Regexp.new(s)
    rescue => e
      return "Invalid regexp /#{s}/: #{e.message}"
    end
    @data.split_regexp = regexp
    "New split regexp: /#{regexp}/"
  end

  def regexp_line_highlight_prompt
    s = @display.prompt("Highlight regexp(/#{@data.split_regexp}/): ")
    s.strip! if s
    if !s || s.empty?
      @data.highlight_regexp = nil
      return "No line highlight by regexp"
    end
    begin
      s.gsub!(%r{^/|/$}, '')
      regexp = s.empty? ? nil : Regexp.new(s)
    rescue => e
      return "Invalid regexp /#{s}/: #{e.message}"
    end
    @data.highlight_regexp = regexp
    "New highlight regexp: /#{regexp}/"
  end

  def change_separator_prompt
    s = @display.prompt("Separator: ") or return nil
    @display.separator = s
    true
  end

  def change_padding_prompt
    s = @display.prompt("Padding: ") or return nil
    @display.padding = s
    true
  end

  def display_help
    Ncurses.endwin
    Help.display
    true
  rescue => e
    e.message
  ensure
    Ncurses.refresh
  end

  def export_prompt
    format = @display.prompt("Format: ") or return nil
    s = @display.prompt("Lines: ") or return nil
    ls, le = s.split.map { |x| x.to_i }
    file = @display.prompt("File: ") or return nil
    qs = Export.questions(format)
    opts = {}
    qs && qs.each { |k, pt, init|
      s = @display.prompt(pt + ": ", :init => init) or return nil
      opts[k] = s
    }
    len = Export.export(file, format, ls..le, @data, @display, opts)
    "Wrote #{len} bytes"
  rescue => e
    return "Error: #{e.message}"
  end
end
