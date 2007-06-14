module Export
  Format = {}

  def self.export(file, format, lines, data, display)
    mod = Format[format] or raise "Unsupported format '#{format}'"
    line_s = lines.begin
    line_e = lines.end
    if !line_s.kind_of?(Integer) || !line_e.kind_of?(Integer) ||
        line_s > line_e || line_s < 0
      raise "Invalid line range '#{lines}'"
    end

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

    lines = proc  { |b|
      data.lines(nb_lines) { |l|
        next if l.kind_of?(IgnoredLine)
        a = l.values_at(*col_show)
        b.call(a)
      }
    }
    class << lines
      def each(&b); self.call(b); end
    end
    
    columns = if display.col_names
                display.col_headers.values_at(*col_show)
              else
                nil
              end
    
    
    File.open(file, "w") { |fd|
      mod.export(fd, nb_col, lines, columns)
      return fd.pos
    }
  ensure
    data.clear_cache
    data.goto_line(current_line)
  end
end

module Export::TeX
  Export::Format["tex"] = self

  def self.export(io, nb_col, lines, headers)
    io << "\\begin{tabular}{|" << (["c"] * nb_col).join("|") << "|}\\hline\n"
    if headers
      io << headers.join(" & ") 
      io << "\\tabularnewline\\hline\\hline\n"
    end
    lines.each { |a|
      a.map! { |t| t && t.gsub(/\&/, '\&').gsub(/\\/, "\\textbackslash{}") }
      io << a.join(" & ") << "\\tabularnewline\\hline\n"
    }
    io << "\\end{tabular}\n"
  end
end

module Export::CSV
  Export::Format["csv"] = self

  def self.export(io, nb_col, lines, headers)
    require 'csv'
    
    CSV::Writer.generate(io) { |csv|
      csv << headers if headers
      lines.each { |a| csv << a }
    }
  end
end
