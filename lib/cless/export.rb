module Export
  Format = {}
end

module Export::TeX
  Export::Format["tex"] = self

  def self.export(io, lines, data, display)
    line_s = lines.begin
    line_e = lines.end
    if !line_s.kind_of?(Integer) || !line_e.kind_of?(Integer) ||
        line_s > line_e || line_s < 0
      raise "Invalid line range #{lines}"
    end

    __export(io, line_s, line_e, data, display)
  end

  def __export(io, line_s, line_e, data, display)
    current_line = data.line + 1
    nb_lines = line_e - line_s + 1
    data.goto_line(line_s)
    data.cache_fill(nb_lines)
    nb_col = data.sizes.size
    
    col_start = display.col_start
    hidden = display.col_hidden
    hidden.map! { |x| x - col_start }   # Make it 0 based
    col_show = (0...nb_col).to_a - hidden
    nb_col = col_show.size
    
    io << "\\begin{tabular}{|" << (["c"] * nb_col).join("|") << "|}\\hline\n"
    if display.col_names
      io << display.col_headers.values_at(*col_show).join(" & ") 
      io << "\\tabularnewline\\hline\\hline\n"
    end
    data.lines(nb_lines) { |l|
      next if l.kind_of?(IgnoredLine)
      a = l.values_at(*col_show)
      a.map! { |t| t && t.gsub(/\&/, '\&').gsub(/\\/, "\\textbackslash{}") }
      io << a.join(" & ") << "\\tabularnewline\\hline\n"
    }
    io << "\\end{tabular}\n"
  ensure
    data.clear_cache
    data.goto_line(current_line)
  end
  module_function :__export
end
