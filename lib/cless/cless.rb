#require 'ncurses'
require 'rubygems'
require 'ncursesw'
begin
  require 'mmap'
  $have_mmap = true
rescue LoadError
  $have_mmap = false
end
require 'tempfile'

require 'cless/data'
require 'cless/display'
require 'cless/optionsdb'
require 'cless/export'
require 'cless/help'

# For short :)
NC = Ncurses
C = Curses

def select_or_cancel(*fds)
  ifds = [$stdin] + fds.dup
  loop {
    ofds = select(ifds)[0]
    if ofds.delete($stdin)
      return nil if Ncurses.getch == C::ESC
    end
    return ofds unless ofds.empty?
  }
end

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
    "toggle_hide_ignored" => :toggle_hide_ignored,
    "toggle_headers" => :show_hide_headers,
    "change_headers_to_line" => :change_headers_to_line_content_prompt,
    "toggle_line_highlight" => :toggle_line_highlight,
    "toggle_column_highlight" => :toggle_column_highlight,
    "shift_line_highlight" => :shift_line_highlight,
    "shift_column_highlight" => :shift_column_highlight,
    "regexp_line_highlight" => :regexp_line_highlight_prompt,
    "column_align_left" => :column_align_left,
    "column_align_right" => :column_align_right,
    "column_align_center" => :column_align_center,
    "column_align_auto" => :column_align_auto,
    "right_align_regexp" => :right_align_regexp_prompt,
    "column_width" => :column_width_prompt,
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

  attr_accessor :max_search_history, :search_history
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
    @search_history = []
    @max_search_history = 100
  end

  def done; @done = true; end
  def interrupt_set; @interrupt = true; end
  def interrupt_reset; i, @interrupt = @interrupt, false; i; end

  def ttyname
    [Proc.new { File.readlink("/proc/self/fd/0") },
     Proc.new { `tty`.chomp }].each { |m|
      begin
        return m.call
      rescue Errno::ENOENT
      end
    }
    return "/dev/unknown"
  end

  def load_history(file)
    tty = ttyname
    history = File.open(file, "r") { |fd|
      fd.flock(File::LOCK_SH)
      YAML::load(fd)
    }
    history = {} unless Hash === history
    history["tty"] = {} unless Hash === history["tty"]
    tty_history = history["tty"][tty] || history["tty"][history["recent_tty"]] || {}
    @search_history = tty_history["search"] || []
  rescue Errno::EACCES
  rescue Errno::ENOENT
  end

  def save_history(file)
    tty = ttyname
    File.open(file, File::RDWR|File::CREAT, 0644) { |fd|
      fd.flock(File::LOCK_EX)

      history = YAML::load(fd)
      history = {} unless Hash === history
      history["tty"] = {} unless Hash === history["tty"]
      history["tty"][tty] = {} unless Hash === history["tty"][tty]
      history["tty"][tty]["search"] = @search_history
      history["recent_tty"] = tty

      fd.rewind
      fd.print(history.to_yaml)
      fd.flush
      fd.truncate(fd.pos)
    }
  rescue Errno::EACCES
  rescue Errno::ENOENT
  end

  def main_loop
    if @status.empty?
      @status = "Help? Press ~ or F1"
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
      data_fd = @data.select_fd(@display.nb_lines)
      prompt = data_fd ? "+:" : ":"
      @display.wait_status(@status, prompt + @prebuff)
      if data_fd
        @display.flush
        in_fds = select([$stdin, data_fd])
        if in_fds[0].include?(data_fd)
          status = :more
          nc = true
          break
        end
      end

      k = Ncurses.getch
      status = 
        case k
        when NC::KEY_DOWN, NC::KEY_ENTER, C::CTRL_N, ?e.ord, C::CTRL_E, ?j.ord, C::CTRL_J, ?\n.ord, ?\r.ord
          scroll_forward_line
        when NC::KEY_UP, ?y.ord, C::CTRL_Y, C::CTRL_P, ?k.ord, C::CTRL_K
          scroll_backward_line
        when ?d.ord, C::CTRL_D; scroll_forward_half_screen(true)
        when ?u.ord, C::CTRL_U; scroll_backward_half_screen(true)
        when C::SPACE, NC::KEY_NPAGE, C::CTRL_V, ?f.ord, C::CTRL_F; scroll_forward_full_screen
        when ?z.ord; scroll_forward_full_screen(true)
        when NC::KEY_PPAGE, ?b.ord, C::CTRL_B; scroll_backward_full_screen
        when ?w.ord; scroll_backward_full_screen(true)
        when NC::KEY_HOME, ?g.ord, ?<.ord; goto_line(0)
        when NC::KEY_END, ?G.ord, ?>.ord; goto_line(-1)
        when NC::KEY_LEFT; scroll_left
        when NC::KEY_RIGHT; scroll_right
        when ?+.ord; @display.col_space += 1; true
        when ?-.ord; @display.col_space -= 1; true
        when ?F.ord; goto_position_prompt
        when ?v.ord; column_format_prompt
        when ?i.ord; ignore_line_prompt
        when ?I.ord; ignore_line_remove_prompt
        when ?o.ord; toggle_line_highlight
        when ?O.ord; toggle_column_highlight
        when ?m.ord; shift_line_highlight
        when ?M.ord; shift_column_highlight
        when ?c.ord; @display.column = !@display.column; true
        when ?l.ord; @display.line = !@display.line; true
        when ?L.ord; @display.line_offset = !@display.line_offset; true
        when ?h.ord; hide_columns_prompt
        when ?H.ord; hide_columns_prompt(:show)
        when ?A.ord; column_alignment(:right)
        when ?a.ord; column_alignment(:left)
        when ?`.ord; change_column_start_prompt
        when ?).ord; esc ? scroll_right : column_width_increase
        when ?(.ord; esc ? scroll_left : column_width_decrease
        when ?/.ord; search_prompt(:forward)
        when ??.ord; search_prompt(:backward)
        when ?n.ord; repeat_search
        when ?N.ord; repeat_search(true)
        when ?s.ord; save_file_prompt
        when ?S.ord; change_split_pattern_prompt
        when ?E.ord; export_prompt
        when ?t.ord; show_hide_headers
        when ?p.ord, ?%.ord; goto_percent
        when ?|.ord; change_separator_prompt
        when ?\\.ord; change_padding_prompt
        when ?^.ord; change_headers_to_line_content_prompt
        when ?r.ord, ?R.ord, C::CTRL_R, C::CTRL_L; @data.clear_cache; NC::endwin; NC::doupdate
        when NC::KEY_RESIZE; nc = true # Will break to refresh display
        when NC::KEY_F1, ?~.ord; display_help
        when (?0.ord)..(?9.ord); @prebuff += k.chr; next
        when NC::KEY_BACKSPACE, ?\b.ord; esc ? @prebuff = "" : @prebuff.chop!; next
        when ?:.ord; long_command
        when ?q.ord; return nil
        when C::ESC; esc = true; next
        when NC::KEY_SLEFT, ?[.ord; column_offset_left
        when NC::KEY_SRIGHT, ?].ord; column_offset_right
        when ?{.ord; column_offset_start
        when ?}.ord; column_offset_end
        else next
        end
      break
    end
    
    @prebuff = "" unless nc
    @status = 
      case status
      when String; status
      when nil; "Cancelled"
      when :more; @status
      else ""
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
      when NC::KEY_DOWN, C::CTRL_N; sub.next_item
      when NC::KEY_UP, C::CTRL_P; sub.previous_item
      else r = false
      end
      Ncurses.refresh if r
    }
    s = @display.prompt("Filter: ", :extra => extra, :other => other)
    sub.destroy
    @display.refresh
    self.__send__(Commands[sub.item]) if s
  end

  def str_to_range(str)
    str.split_with_quotes().map { |r|
      case r
      when /^(\d+)$/
        $1.to_i
      when /^(\d+)(?:\.{2,3}|-)(\d+)$/
        (($1.to_i)..($2.to_i)).to_a
      else raise "Invalid range: #{r}"
      end
    }.flatten
  end

  def range_prompt(prompt)
    s = @display.prompt(prompt) or return nil
    str_to_range(s)
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

  def scroll_sideways(dir)
    @scroll_columns = prebuff if prebuff
    to_scroll = @scroll_columns || 1
    st_col = @display.st_col
    to_scroll.times { |i|
      st_col += dir
      redo if @display.col_hidden(false).index(st_col)
    }
    @display.st_col = st_col
    true
  end

  def scroll_left; scroll_sideways(-1); end
  def scroll_right; scroll_sideways(1); end

  def column_offset_sideways(dir)
    if prebuff && prebuff >= @display.col_start
      @offset_column = prebuff - @display.col_start
    end
    return if @offset_column.nil?
    off = @display.col_offsets[@offset_column] || 0
    off = [off + dir, 0].max
    @display.col_offsets[@offset_column] = off
  end

  def column_offset_right; column_offset_sideways(1); end
  def column_offset_left; column_offset_sideways(-1); end
  def column_offset_start
    if prebuff && prebuff >= @display.col_start
      @offset_column = prebuff - @display.col_start
    end
    return if @offset_column.nil?
    @display.col_offsets[@offset_column] = 0
  end

  def column_offset_end
    if prebuff && prebuff >= @display.col_start
      @offset_column = prebuff - @display.col_start
    end
    return if @offset_column.nil?
    @display.col_offsets[@offset_column] =
      [0, @data.sizes[@offset_column] - (@display.widths[@offset_column] || @display.col_width)].max
  end

  def goto_line(l)
    if l == 0
      return @data.goto_start ? "" : "Start of file"
    elsif l < 0
        @display.start_active_status("Skipping to end of file")
        return @data.goto_end ? "" : "End of file"
    else
      @display.start_active_status("Skipping to line #{l}")
      @data.goto_line(prebuff)
    end
    true
  ensure
    @display.end_active_status
  end

  def unhide_columns; hide_columns_prompt(true); end
  def hide_columns_prompt(show = false)
    i = prebuff
    a = i ? [i] : range_prompt(show ? "Show: " : "Hide: ") or return nil
    if a.empty?
      @display.col_hide_clear
    else
      show ? @display.col_show(*a) : @display.col_hide(*a)
    end
    "Hidden: #{@display.col_hidden.join(" ")}"
  rescue => e
    return e.message
  end

  def toggle_hide_ignored; @display.hide_ignored = !@display.hide_ignored; end

  def column_align_left; column_alignment(:left); end
  def column_align_right; column_alignment(:right); end
  def column_align_center; column_alignment(:center); end
  def column_align_auto; column_alignment(nil); end
  def column_alignment(align)
    i = prebuff
    a = i ? [i] : range_prompt("Columns to #{align || "auto"} align: ") or return nil
    return if a.empty?
    @display.col_align(align, a)
  end

  def column_width_prompt
    i = prebuff
    a = i ? [i] : range_prompt("Width of columns: ") or return nil
    return nil if a.empty?
    s = @display.prompt("Max width: ") or return nil
    s = [s.to_i, 5].max
    a.map { |x| @display.widths[x] = s }
  end

  def column_width_change(x)
    if prebuff && prebuff >= @display.col_start
      @offset_column = prebuff - @display.col_start
    end
    return if @offset_column.nil?
    w = (@display.widths[@offset_column] || @display.col_width) + x
    w = 5 if w < 5
    @display.widths[@offset_column] = w
  end

  def column_width_increase; column_width_change(1); end
  def column_width_decrease; column_width_change(-1); end

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
                          [(dir == :forward) ? "Forward" : "Backward"],
                        { :history => @search_history })
    s or return nil
    if s =~ /^\s*$/
      @data.search_clear
    else
      begin
        @display.start_active_status("Searching '#{s}'")

        hist_index = @search_history.index(s)
        @search_history.slice!(hist_index) if hist_index
        @search_history.unshift(s)
        @search_history = @search_history[0, @max_search_history]
        begin
          @search_dir = dir
          pattern = Regexp.new(s)
          @data.search(pattern, dir) or return "Pattern not found!"
        rescue RegexpError => e
        return "Bad attr_reader :egexp: #{e.message}"
        end
      ensure
        @display.end_active_status
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
    if @data.file_path
      begin
        File.link(@data.file_path, s)
        return "Hard linked"
      rescue Errno::EXDEV => e
      rescue Exception => e
        return "Error: #{e.message}"
      end
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
    s = prebuff || @display.prompt("Goto: ") or return nil
    s = s.to_s.strip

    case s[-1]
    when "p", "%"
      s.slice!(-1)
      f = s.to_f
      return "Invalid percentage" if f <= 0.0 || f > 100.0
      @display.start_active_status("Goto %d%%" % f.round)
      @data.goto_percent(f)
    when "o"
      s.slice!(-1)
      i = s.to_i
      return "Invalid offset" if i < 0
      @display.start_active_status("Goto offset #{i}")
      @data.goto_offset(i)
    else
      i = s.to_i
      return "Invalid line number" if i <= 0
      @display.start_active_status("Goto line #{i}")
      @data.goto_line(i)
    end
    true
  ensure
    @display.end_active_status
  end

  def column_format_prompt
    i = prebuff
    cols = i ? [i] : range_prompt("Format columns: ") or return nil
    fmt = @display.prompt("Format string: ") or return nil
    fmt.strip!
    column_format(cols, fmt)
  rescue => e
    return e.message
  end

  def column_format_inline(str)
    cols, fmt = str.split(/:/, 2)
    cols = str_to_range(cols)
    column_format(cols, fmt)
  end

  def column_format(cols, fmt)
    inc = @display.col_start
    if cols
      cols = cols.map { |x| x.to_i - inc }
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
             when /^(\d+)(?:\.{2}|-)(\d+)$/; ($1.to_i - 1)..($2.to_i - 1)
             when /^(\d+)$/; $1.to_i - 1
             else Regexp.new(spat) rescue nil
             end
      yield(spat, opat)
    end
  end

  def ignore_line_list_display(a)
    a.collect { |x|
      o = case x
          when Range; (x.begin + 1)..(x.end + 1)
          when Integer; x + 1
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

  def right_align_regexp_prompt
    current = @display.right_align_re == LineDisplay::ISNUM ? "number" : @display.right_align_re.to_s
    s = @display.prompt("Right align regexp(/#{current}/): ")
    s.strip! if s
    if s.nil? || s.empty?
      @display.right_align_re = LineDisplay::ISNUM
      return "Automatic right alignment of numbers"
    elsif s == "//"
      @display.right_align_re = nil
      return "No automatic right alignment"
    end

    begin
      s.gsub!(%r{^/|/$}, '')
      regexp = Regexp.new(s)
    rescue => e
      return "Invalid regexp /#{s}/: #{e.message}"
    end
    @display.right_align_re = regexp
    "Automatic right alignment regexp: /#{regexp}/"
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
