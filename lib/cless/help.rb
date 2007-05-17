module Help
  CONTENT = <<EOF
          CLESS HELP
        Press q to quit

 Key binding
 ===========

 ARROW_DOWN, ENTER, e:         scroll one line down
 SPACE BAR, PAGE_DOWN, f:      scroll one page down
 ARROW_UP, y:                  scroll one line up
 PAGE_UP, b:                   scroll one page up
 ARROW_RIGHT:                  scroll one column to the right
 ARROW_LEFT:                   scroll one column to the left
 HOME, g, <:                   go to top of file
 END, G, >:                    go to end of file
 +:                            increase column spacing
 -:                            decrease column spacing
 1:                            change foreground colors for highlight
 2:                            change background colors for highlight
 3:                            change attributes for hilight
 0:                            toggle 0-based / 1-based column numbering
 c:                            show/hide the column numbers
 l:                            show/hide the line numbers (1 based)
 L:                            show byte offset instead of line number
 h:                            hide column (space separated list)
 H:                            show column (space separated list)
 o:                            toggle highlighting of alternate lines
 O:                            toggle highlighting of alternate columns
 F:                            go to line. 10  -> absolute line number
                                            10o -> absolute offset
                                            10% -> percentage in file
 %:                            format columns. E.g.  10:%.1f
 i:                            ignore lines. Lines or regexp
 I:                            remove ignore lines patterns
 /:                            forward search
 ?:                            backward search
 n:                            repeat previous search
 N:                            repeat previous search, reversed direction
 s:                            save content to file
 S:                            change split regexp
 t:                            toggle column names
 T:                            change column names (BROKEN)
 ^:                            use a line from file for column headers
 r:                            refresh display
 q:                            quit

 Notes on Searching
 ==================

 The search patterns are Perl compatible regular expressions. It is ill
 advised to use patterns that match white spaces as the spaces are
 ignored when displayed. I.e., a match MUST be contained within a
 column to be properly displayed. If a match span accross columns,
 strange behavior may occure.  To force a match to be the entire column
 width, use the word boundary anchor: \\b. E.g., to match the line with
 a column having only 0 (instead of any column which contains a 0), use
 the following pattern: \\b0\\b.
 
 Note also that the match might be in a hidden column. In any case, if
 the line numbers are displayed, a line having a match will have its
 line number in reverse video.

 More details at http://genome1.umd.edu
EOF


  OPTIONS = "--no-column --no-line --no-offset --no-line-highlight " +
    "--no-column-highlight --no-column-names --no-parse-header " +
    "--ignore '/^\s/'"

  def self.display
    io = open("|#{$0} #{OPTIONS}", "w")
    io.write(CONTENT)
    io.close
    Process.wait rescue nil
  end
end
