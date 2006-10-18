require 'ncurses'
require 'mmap'
require 'tempfile'
require 'mmap'

require 'cless/data'
require 'cless/display'
require 'cless/optionsdb'

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
  def initialize(data, display, curses, db)
    @data = data
    @display = display
    @curses = curses
    @db = db
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
      when ?f: status = goto_position; break
      when ?%: status = column_format_prompt; break
      when ?i: status = ignore_line_prompt; break
      when ?I: status = ignore_line_remove_prompt; break
      when ?g: @display.grey = !@display.grey; break
      when ?c: @display.column = !@display.column; break
      when ?l: @display.line = !@display.line; break
      when ?L: @display.line_offset = !@display.line_offset; break;
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
      when ?s: status = save_file; break
      when ?t: status = show_hide_headers; break
      when ?T: status = change_headers; break
      when ?r: @data.clear_cache; break
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

  def show_hide_headers
    return "No names defined" if !@display.col_names && !@display.col_headers
    @display.col_names = !@display.col_names
    return nil
  end

  def change_headers
    s = @display.prompt("Pattern: ") or return "Canceled"
    a = @db.find(s.strip) or return "Pattern not found"
    @display.col_headers = a
    nil
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
        @data.search(pattern, dir) or return "Pattern not found!"
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

  def save_file
    s = @display.prompt("Save to: ")
    return "Canceled" if !s || s.empty?
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

  def goto_position
    s = @display.prompt("Goto: ") or return "Canceled"
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
    nil
  end

  def column_format_prompt
    s = @display.prompt("Format: ") or return "Canceled"
    s.strip!
    column_format(s)
  end
  
  def column_format(s)
    cols, fmt = s.split(/:/, 2)
    inc = @display.col_zero ? 0 : 1
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

  def ignore_line_prompt
    s = @display.prompt("Ignore: ") or return "Canceled"
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
    s = @display.prompt("Remove ignore: ") or return "Canceled"
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
end
