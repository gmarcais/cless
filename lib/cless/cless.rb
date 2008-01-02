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

class Manager
  class Error < StandardError; end

  def initialize(data, display, db)
    @data = data
    @display = display
    @db = db
    @done = false
    @status = ""
  end

  def done; @done = true; end

  def main_loop
    if @status.empty?
      @status = "Help? Press a or F1"
    end
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
      status = 
        case k = Ncurses.getch
        when Ncurses::KEY_DOWN, Ncurses::KEY_ENTER, ?e, ?\n, ?\r
          @data.scroll(1); true
        when Ncurses::KEY_UP, ?y: @data.scroll(-1); true
        when " "[0], Ncurses::KEY_NPAGE, ?f: 
            @data.scroll(@display.nb_lines - 1); true
        when Ncurses::KEY_PPAGE, ?b: @data.scroll(1 - @display.nb_lines); true
        when Ncurses::KEY_HOME, ?g, ?<: @data.goto_start; true
        when Ncurses::KEY_END, ?G, ?>: @data.goto_end; true
        when Ncurses::KEY_LEFT: @display.st_col -= 1; true
        when Ncurses::KEY_RIGHT: @display.st_col += 1; true
        when ?+: @display.col_space += 1; true
        when ?-: @display.col_space -= 1; true
        when ?F: goto_position_prompt
        when ?%: column_format_prompt
        when ?i: ignore_line_prompt
        when ?I: ignore_line_remove_prompt
        when ?o: @display.line_highlight = !@display.line_highlight; true
        when ?O: @display.col_highlight = !@display.col_highlight; true
        when ?c: @display.column = !@display.column; true
        when ?l: @display.line = !@display.line; true
        when ?L: @display.line_offset = !@display.line_offset; true
        when ?h: hide_columns_prompt
        when ?H: hide_columns_prompt(:show)
        when ?0: @display.col_start = (@display.col_start == 0) ? 1 : 0; true
        when ?): change_column_start_prompt
        when ?1: @display.next_foreground; color_descr
        when ?2: @display.next_background; color_descr
        when ?3: @display.next_attribute; color_descr
        when ?/: search_prompt(:forward)
        when ??: search_prompt(:backward)
        when ?n: repeat_search
        when ?N: repeat_search(true)
        when ?s: save_file_prompt
        when ?S: change_split_pattern_prompt
        when ?E: export_prompt
        when ?t: show_hide_headers
        when ?T: change_headers_prompt
        when ?p: change_separator_prompt
        when ?P: change_padding_prompt
        when ?^: change_headers_to_line_content_prompt
        when ?r: @data.clear_cache; Ncurses::endwin; Ncurses::doupdate
        when Ncurses::KEY_RESIZE: # Will break to refresh display
        when Ncurses::KEY_F1, ?a: display_help
        when ?q: return nil
        else 
          next
        end
      
      break
    end
    
    @status = 
      case status
      when String: status
      when nil: "Cancelled"
      else
        ""
      end
    return true
  end

  def hide_columns_prompt(show = false)
    s = @display.prompt(show ? "Show: " : "Hide: ") or return nil
    a = s.split.collect { |x| x.to_i }
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

  def change_headers_prompt
    s = @display.prompt("Pattern: ") or return nil
    a = @db.find(s.strip) or return "Pattern not found"
    @display.col_headers = a
    true
  end

  def change_headers_to_line_content_prompt
    i = @data.line + 1
    s = @display.prompt("Header line: ", i.to_s) or return nil
    s.strip!
    return "Bad line number #{s}" unless s =~ /^\d+$/
    i = s.to_i
    begin
      change_headers_to_line(i)
    rescue => e
      return e.message
    end
    true
  end

  def change_headers_to_line(i)
    raise Error, "Bad line number #{i}" if i < 1
    i_bak = @data.line + 1
    @data.goto_line(i)
    line = nil
    @data.lines(1) { |l| line = l }
    @data.goto_line(i_bak)     # Go back
    raise Error, "No such line" unless line
    raise Error, "Ignored line: can't use" if line.kind_of?(IgnoredLine)
    @display.col_headers = line.values_at(0..-1)
    @display.col_names = true
    true
  end

  # Return a status if an error occur, otherwise, returns nil
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
      @data.clear_cache
    end
    cols = @data.formatted_column_list.sort.collect { |x| x + inc }
    "Formatted: " + cols.join(" ")
  end

  def change_column_start_prompt
    s = @display.prompt("First column: ") or return nil
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
    @data.clear_cache
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
    @data.clear_cache
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
      s = @display.prompt(pt + ": ", init) or return nil
      opts[k] = s
    }
    len = Export.export(file, format, ls..le, @data, @display, opts)
    "Wrote #{len} bytes"
  rescue => e
    return "Error: #{e.message}"
  end
end
