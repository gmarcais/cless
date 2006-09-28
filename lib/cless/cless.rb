require 'ncurses'
require 'mmap'
require 'tempfile'
require 'mmap'

require 'cless/data'
require 'cless/display'
require 'cless/namedb'

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
      when ?s: status = save_file; break
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
end
