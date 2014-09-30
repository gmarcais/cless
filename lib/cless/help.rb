module Help
  CONTENT = <<EOF
          CLESS HELP
        Press q to quit

 Key binding
 ===========

 Key binding is mostly compatible with the original less.

 ARROW_DOWN, ENTER, ^N, ^E, j     scroll down one line
 SPACE BAR, PAGE_DOWN, ^V, ^F, f  scroll down one page
 ARROW_UP, ^Y, ^P, ^K, y, k       scroll up one line
 PAGE_UP, ^B, b                   scroll up one page
 ARROW_RIGHT, ESC-)               scroll right one column
 ARROW_LEFT, ESC-(                scroll left one column
 d                                scroll down half screen
 u                                scroll up half screen
 HOME, g, <                       go to top of file
 END, G, >                        go to end of file
 +                                increase column spacing
 -                                decrease column spacing
 c                                show/hide the column numbers
 l                                show/hide the line numbers (1 based)
 L                                show byte offset instead of line number
 h                                hide column (space separated list)
 H                                show column (space separated list)
 ` (back-tick)                    change first column index
 o                                toggle highlighting of alternate lines
 O                                toggle highlighting of alternate columns 
 m                                shift line highlighting start
 M                                shift column highlighting start
 F                                go to. 10  -> absolute line number
                                         10o -> absolute offset
                                         10% -> percentage in file
 p                                go to percentage.
 v                                format columns.
 i                                ignore lines. Lines or regexp
 I                                remove ignore lines patterns
 /                                forward search
 ?                                backward search
 n                                repeat previous search
 N                                repeat previous search, reversed direction
 s                                save content to file
 E                                export content to some format (tex, csv)
 S                                change split regexp
 t                                toggle column names
 ^                                use a line from file for column headers
 |                                change column separator character
 [                                shift content of a column to the left
 ]                                shift content of a column to the right
 {                                shift content of a column to the start
 }                                shift content of a column to the end
 (                                reduce width of a column
 )                                increase width of a column
 \\                               change column padding string
 r, R, ^R, ^L                     refresh display
 :                                command menu
 q                                quit

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

 Environment variable
 ====================

 If set, the environment variable CLESS gives switches to be added to the
 switches found on the command line. For example, to always display the line
 numbers and columns:
    CLESS="--lines --column"
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
