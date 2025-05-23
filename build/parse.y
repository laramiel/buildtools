/*
Copyright 2020 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// BUILD file parser.

// This is a yacc grammar. Its lexer is in lex.go.
//
// For a good introduction to writing yacc grammars, see
// Kernighan and Pike's book The Unix Programming Environment.
//
// The definitive yacc manual is
// Stephen C. Johnson and Ravi Sethi, "Yacc: A Parser Generator",
// online at http://plan9.bell-labs.com/sys/doc/yacc.pdf.

%{
package build
%}

// The generated parser puts these fields in a struct named yySymType.
// (The name %union is historical, but it is inaccurate for Go.)
%union {
	// input tokens
	tok       string     // raw input syntax
	str       string     // decoding of quoted string
	pos       Position   // position of token
	triple    bool       // was string triple quoted?

	// partial syntax trees
	expr      Expr
	exprs     []Expr
	kv        *KeyValueExpr
	kvs       []*KeyValueExpr
	string    *StringExpr
	ifstmt    *IfStmt
	loadarg   *struct{from Ident; to Ident}
	loadargs  []*struct{from Ident; to Ident}
	def_header *DefStmt  // partially filled in def statement, without the body

	// supporting information
	comma     Position   // position of trailing comma in list, if present
	lastStmt  Expr  // most recent rule, to attach line comments to
}

// These declarations set the type for a $ reference ($$, $1, $2, ...)
// based on the kind of symbol it refers to. Other fields can be referred
// to explicitly, as in $<tok>1.
//
// %token is for input tokens generated by the lexer.
// %type is for higher-level grammar rules defined here.
//
// It is possible to put multiple tokens per line, but it is easier to
// keep ordered using a sparser one-per-line list.

%token	<pos>	'%'
%token	<pos>	'('
%token	<pos>	')'
%token	<pos>	'*'
%token	<pos>	'+'
%token	<pos>	','
%token	<pos>	'-'
%token	<pos>	'.'
%token	<pos>	'/'
%token	<pos>	':'
%token	<pos>	'<'
%token	<pos>	'='
%token	<pos>	'>'
%token	<pos>	'['
%token	<pos>	']'
%token	<pos>	'{'
%token	<pos>	'}'
%token	<pos>	'|'
%token	<pos>	'&'
%token	<pos>	'^'
%token	<pos>	'~'

// By convention, yacc token names are all caps.
// However, we do not want to export them from the Go package
// we are creating, so prefix them all with underscores.

%token	<pos>	_AUGM    // augmented assignment
%token	<pos>	_AND     // keyword and
%token	<pos>	_COMMENT // top-level # comment
%token	<pos>	_EOF     // end of file
%token	<pos>	_EQ      // operator ==
%token	<pos>	_FOR     // keyword for
%token	<pos>	_GE      // operator >=
%token	<pos>	_IDENT   // non-keyword identifier
%token	<pos>	_INT     // integer number
%token	<pos>	_IF      // keyword if
%token	<pos>	_ELSE    // keyword else
%token	<pos>	_ELIF    // keyword elif
%token	<pos>	_IN      // keyword in
%token	<pos>	_IS      // keyword is
%token	<pos>	_LAMBDA  // keyword lambda
%token	<pos>	_LOAD    // keyword load
%token	<pos>	_LE      // operator <=
%token	<pos>	_NE      // operator !=
%token	<pos>	_STAR_STAR // operator **
%token	<pos>	_INT_DIV // operator //
%token	<pos>	_BIT_LSH // bitwise operator <<
%token	<pos>	_BIT_RSH // bitwise operator >>
%token	<pos>	_ARROW   // functions type annotation ->
%token	<pos>	_NOT     // keyword not
%token	<pos>	_OR      // keyword or
%token	<pos>	_STRING  // quoted string
%token	<pos>	_DEF     // keyword def
%token	<pos>	_RETURN  // keyword return
%token	<pos>	_PASS    // keyword pass
%token	<pos>	_BREAK   // keyword break
%token	<pos>	_CONTINUE // keyword continue
%token	<pos>	_INDENT  // indentation
%token	<pos>	_UNINDENT // unindentation

%type	<pos>		comma_opt
%type	<pos>		commas
%type	<pos>		commas_opt
%type	<expr>		argument
%type	<exprs>		arguments
%type	<exprs>		arguments_opt
%type	<expr>		parameter
%type	<exprs>		parameters
%type	<exprs>		parameters_opt
%type	<expr>		parameter_type
%type	<exprs>		parameters_type
%type	<exprs>		parameters_type_opt
%type	<expr>		test
%type	<expr>		test_opt
%type	<exprs>		tests_opt
%type	<expr>		primary_expr
%type	<expr>		expr
%type	<expr>		expr_opt
%type	<exprs>		tests
%type	<expr>		loop_vars
%type	<expr>		for_clause
%type	<exprs>		for_clause_with_if_clauses_opt
%type	<exprs>		for_clauses_with_if_clauses_opt
%type	<expr>		ident
%type	<expr>		number
%type	<exprs>		stmts
%type	<exprs>		stmt          // a simple_stmt or a for/if/def block
%type	<expr>		block_stmt    // a single for/if/def statement
%type	<ifstmt>	if_else_block // a complete if-elif-else block
%type	<ifstmt>	if_chain      // an elif-elif-else chain
%type	<pos>		elif          // `elif` or `else if` token(s)
%type	<exprs>		simple_stmt   // One or many small_stmts on one line, e.g. 'a = f(x); return str(a)'
%type	<expr>		small_stmt    // A single statement, e.g. 'a = f(x)'
%type	<exprs>		small_stmts_continuation  // A sequence of `';' small_stmt`
%type	<kv>		keyvalue
%type	<kvs>		keyvalues
%type	<kvs>		keyvalues_no_comma
%type	<string>	string
%type	<exprs>		suite
%type	<exprs>		comments
%type	<loadarg>	load_argument
%type	<loadargs>	load_arguments
%type <def_header>	def_header
%type <def_header>	def_header_type_opt

// Operator precedence.
// Operators listed lower in the table bind tighter.

// We tag rules with this fake, low precedence to indicate
// that when the rule is involved in a shift/reduce
// conflict, we prefer that the parser shift (try for a longer parse).
// Shifting is the default resolution anyway, but stating it explicitly
// silences yacc's warning for that specific case.
%left	ShiftInstead

%left	'\n'
%left	_ASSERT
// '=' and augmented assignments have the lowest precedence
// e.g. "x = a if c > 0 else 'bar'"
// followed by
// 'if' and 'else' which have lower precedence than all other operators.
// e.g. "a, b if c > 0 else 'foo'" is either a tuple of (a,b) or 'foo'
// and not a tuple of "(a, (b if ... ))"
%left  '=' _AUGM
%left  _IF _ELSE _ELIF
%left  ','
%left  ':'
%left  _IS
%left  _OR
%left  _AND
%left  '<' '>' _EQ _NE _LE _GE _NOT _IN
%left  '|'
%left  '^'
%left  '&'
%left  _BIT_LSH _BIT_RSH
%left  '+' '-'
%left  '*' '/' '%' _INT_DIV
%left  '.' '[' '('
%left  _STRING
%right _UNARY

%%

// Grammar rules.
//
// A note on names: if foo is a rule, then foos is a sequence of foos
// (with interleaved commas or other syntax as appropriate)
// and foo_opt is an optional foo.

file:
	stmts _EOF
	{
		yylex.(*input).file = &File{Stmt: $1}
		return 0
	}

suite:
	'\n' comments _INDENT stmts _UNINDENT
	{
		statements := $4
		if $2 != nil {
			// $2 can only contain *CommentBlock objects, each of them contains a non-empty After slice
			cb := $2[len($2)-1].(*CommentBlock)
			// $4 can't be empty and can't start with a comment
			stmt := $4[0]
			start, _ := stmt.Span()
			if start.Line - cb.After[len(cb.After)-1].Start.Line == 1 {
				// The first statement of $4 starts on the next line after the last comment of $2.
				// Attach the last comment to the first statement
				stmt.Comment().Before = cb.After
				$2 = $2[:len($2)-1]
			}
			statements = append($2, $4...)
		}
		$$ = statements
		$<lastStmt>$ = $<lastStmt>4
	}
|	simple_stmt linebreaks_opt %prec ShiftInstead
	{
		$$ = $1
	}

linebreaks_opt:
| linebreaks_opt '\n'

comments:
	{
		$$ = nil
		$<lastStmt>$ = nil
	}
|	comments _COMMENT '\n'
	{
		$$ = $1
		$<lastStmt>$ = $<lastStmt>1
		if $<lastStmt>$ == nil {
			cb := &CommentBlock{Start: $2}
			$$ = append($$, cb)
			$<lastStmt>$ = cb
		}
		com := $<lastStmt>$.Comment()
		com.After = append(com.After, Comment{Start: $2, Token: $<tok>2})
	}
|	comments '\n'
	{
		$$ = $1
		$<lastStmt>$ = nil
	}

stmts:
	{
		$$ = nil
		$<lastStmt>$ = nil
	}
|	stmts stmt
	{
		// If this statement follows a comment block,
		// attach the comments to the statement.
		if cb, ok := $<lastStmt>1.(*CommentBlock); ok {
			$$ = append($1[:len($1)-1], $2...)
			$2[0].Comment().Before = cb.After
			$<lastStmt>$ = $<lastStmt>2
			break
		}

		// Otherwise add to list.
		$$ = append($1, $2...)
		$<lastStmt>$ = $<lastStmt>2

		// Consider this input:
		//
		//	foo()
		//	# bar
		//	baz()
		//
		// If we've just parsed baz(), the # bar is attached to
		// foo() as an After comment. Make it a Before comment
		// for baz() instead.
		if x := $<lastStmt>1; x != nil {
			com := x.Comment()
			// stmt is never empty
			$2[0].Comment().Before = com.After
			com.After = nil
		}
	}
|	stmts '\n'
	{
		// Blank line; sever last rule from future comments.
		$$ = $1
		$<lastStmt>$ = nil
	}
|	stmts _COMMENT '\n'
	{
		$$ = $1
		$<lastStmt>$ = $<lastStmt>1
		if $<lastStmt>$ == nil {
			cb := &CommentBlock{Start: $2}
			$$ = append($$, cb)
			$<lastStmt>$ = cb
		}
		com := $<lastStmt>$.Comment()
		com.After = append(com.After, Comment{Start: $2, Token: $<tok>2})
	}

stmt:
	simple_stmt
	{
		$$ = $1
		$<lastStmt>$ = $1[len($1)-1]
	}
|	block_stmt
	{
		$$ = []Expr{$1}
		$<lastStmt>$ = $1
		if cbs := extractTrailingComments($1); len(cbs) > 0 {
			$$ = append($$, cbs...)
			$<lastStmt>$ = cbs[len(cbs)-1]
			if $<lastStmt>1 == nil {
				$<lastStmt>$ = nil
			}
		}
	}

def_header:
	_DEF _IDENT '(' parameters_type_opt ')'
	{
		$$ = &DefStmt{
			Function: Function{
				StartPos: $1,
				Params: $4,
			},
			Name: $<tok>2,
			ForceCompact: forceCompact($3, $4, $5),
			ForceMultiLine: forceMultiLine($3, $4, $5),
		}
	}

def_header_type_opt:
	def_header
| def_header _ARROW test
	{
		$1.Type = $3
		$$ = $1
	}

block_stmt:
	def_header_type_opt ':' suite
	{
		$1.Function.Body = $3
		$1.ColonPos = $2
		$$ = $1
		$<lastStmt>$ = $<lastStmt>3
	}
|	_FOR loop_vars _IN expr ':' suite
	{
		$$ = &ForStmt{
			For: $1,
			Vars: $2,
			X: $4,
			Body: $6,
		}
		$<lastStmt>$ = $<lastStmt>6
	}
|	if_else_block
	{
		$$ = $1
		$<lastStmt>$ = $<lastStmt>1
	}

// One or several if-elif-elif statements
if_chain:
	_IF expr ':' suite
	{
		$$ = &IfStmt{
			If: $1,
			Cond: $2,
			True: $4,
		}
		$<lastStmt>$ = $<lastStmt>4
	}
|	if_chain elif expr ':' suite
	{
		$$ = $1
		inner := $1
		for len(inner.False) == 1 {
			inner = inner.False[0].(*IfStmt)
		}
		inner.ElsePos = End{Pos: $2}
		inner.False = []Expr{
			&IfStmt{
				If: $2,
				Cond: $3,
				True: $5,
			},
		}
		$<lastStmt>$ = $<lastStmt>5
	}

// A complete if-elif-elif-else chain
if_else_block:
	if_chain
|	if_chain _ELSE ':' suite
	{
		$$ = $1
		inner := $1
		for len(inner.False) == 1 {
			inner = inner.False[0].(*IfStmt)
		}
		inner.ElsePos = End{Pos: $2}
		inner.False = $4
		$<lastStmt>$ = $<lastStmt>4
	}

elif:
	_ELSE _IF
|	_ELIF

simple_stmt:
	small_stmt small_stmts_continuation semi_opt '\n'
	{
		$$ = append([]Expr{$1}, $2...)
		$<lastStmt>$ = $$[len($$)-1]
	}

small_stmts_continuation:
	{
		$$ = []Expr{}
	}
|	small_stmts_continuation ';' small_stmt
	{
		$$ = append($1, $3)
	}

small_stmt:
	expr %prec ShiftInstead
|	_RETURN expr
	{
		$$ = &ReturnStmt{
			Return: $1,
			Result: $2,
		}
	}
|	_RETURN
	{
		$$ = &ReturnStmt{
			Return: $1,
		}
	}
|	expr '=' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _AUGM expr    { $$ = binary($1, $2, $<tok>2, $3) }
|	_PASS
	{
		$$ = &BranchStmt{
			Token: $<tok>1,
			TokenPos: $1,
		}
	}
|	_BREAK
	{
		$$ = &BranchStmt{
			Token: $<tok>1,
			TokenPos: $1,
		}
	}
|	_CONTINUE
	{
		$$ = &BranchStmt{
			Token: $<tok>1,
			TokenPos: $1,
		}
	}

semi_opt:
|	';'

primary_expr:
	ident
|	number
|	string
	{
		$$ = $1
	}
|	primary_expr '.' _IDENT
	{
		$$ = &DotExpr{
			X: $1,
			Dot: $2,
			NamePos: $3,
			Name: $<tok>3,
		}
	}
|	_LOAD '(' commas_opt string commas load_arguments commas_opt ')'
	{
		load := &LoadStmt{
			Load: $1,
			Module: $4,
			Rparen: End{Pos: $8},
			ForceCompact: $2.Line == $8.Line,
		}
		for _, arg := range $6 {
			load.From = append(load.From, &arg.from)
			load.To = append(load.To, &arg.to)
		}
		$$ = load
	}
|	primary_expr '(' arguments_opt ')'
	{
		$$ = &CallExpr{
			X: $1,
			ListStart: $2,
			List: $3,
			End: End{Pos: $4},
			ForceCompact: forceCompact($2, $3, $4),
			ForceMultiLine: forceMultiLine($2, $3, $4),
		}
	}
|	primary_expr '[' expr ']'
	{
		$$ = &IndexExpr{
			X: $1,
			IndexStart: $2,
			Y: $3,
			End: $4,
		}
	}
|	primary_expr '[' expr_opt ':' test_opt ']'
	{
		$$ = &SliceExpr{
			X: $1,
			SliceStart: $2,
			From: $3,
			FirstColon: $4,
			To: $5,
			End: $6,
		}
	}
|	primary_expr '[' expr_opt ':' test_opt ':' test_opt ']'
	{
		$$ = &SliceExpr{
			X: $1,
			SliceStart: $2,
			From: $3,
			FirstColon: $4,
			To: $5,
			SecondColon: $6,
			Step: $7,
			End: $8,
		}
	}
|	'[' tests_opt ']'
	{
		$$ = &ListExpr{
			Start: $1,
			List: $2,
			End: End{Pos: $3},
			ForceMultiLine: forceMultiLine($1, $2, $3),
		}
	}
|	'[' test for_clauses_with_if_clauses_opt ']'
	{
		$$ = &Comprehension{
			Curly: false,
			Lbrack: $1,
			Body: $2,
			Clauses: $3,
			End: End{Pos: $4},
			ForceMultiLine: forceMultiLineComprehension($1, $2, $3, $4),
		}
	}
|	'{' keyvalue for_clauses_with_if_clauses_opt '}'
	{
		$$ = &Comprehension{
			Curly: true,
			Lbrack: $1,
			Body: $2,
			Clauses: $3,
			End: End{Pos: $4},
			ForceMultiLine: forceMultiLineComprehension($1, $2, $3, $4),
		}
	}
|	'{' keyvalues '}'
	{
		exprValues := make([]Expr, 0, len($2))
		for _, kv := range $2 {
			exprValues = append(exprValues, Expr(kv))
		}
		$$ = &DictExpr{
			Start: $1,
			List: $2,
			End: End{Pos: $3},
			ForceMultiLine: forceMultiLine($1, exprValues, $3),
		}
	}
|	'{' tests comma_opt '}'
	{
		$$ = &SetExpr{
			Start: $1,
			List: $2,
			End: End{Pos: $4},
			ForceMultiLine: forceMultiLine($1, $2, $4),
		}
	}
|	'(' tests_opt ')'
	{
		if len($2) == 1 && $<comma>2.Line == 0 {
			// Just a parenthesized expression, not a tuple.
			$$ = &ParenExpr{
				Start: $1,
				X: $2[0],
				End: End{Pos: $3},
				ForceMultiLine: forceMultiLine($1, $2, $3),
			}
		} else {
			$$ = &TupleExpr{
				Start: $1,
				List: $2,
				End: End{Pos: $3},
				ForceCompact: forceCompact($1, $2, $3),
				ForceMultiLine: forceMultiLine($1, $2, $3),
			}
		}
	}

arguments_opt:
	{
		$$ = nil
	}
|	arguments commas_opt
	{
		$$ = $1
	}

arguments:
	commas_opt argument
	{
		$$ = []Expr{$2}
	}
|	arguments commas argument
	{
		$$ = append($1, $3)
	}

argument:
	test
|	ident '=' test
	{
		$$ = binary($1, $2, $<tok>2, $3)
	}
|	'*' test
	{
		$$ = unary($1, $<tok>1, $2)
	}
|	_STAR_STAR test
	{
		$$ = unary($1, $<tok>1, $2)
	}

load_arguments:
	load_argument {
		$$ = []*struct{from Ident; to Ident}{$1}
	}
| load_arguments ',' load_argument
	{
		$1 = append($1, $3)
		$$ = $1
	}

load_argument:
	string {
		start := $1.Start.add("'")
		if $1.TripleQuote {
			start = start.add("''")
		}
		$$ = &struct{from Ident; to Ident}{
			from: Ident{
				Name: $1.Value,
				NamePos: start,
			},
			to: Ident{
				Name: $1.Value,
				NamePos: start,
			},
		}
	}
| ident '=' string
	{
		start := $3.Start.add("'")
		if $3.TripleQuote {
			start = start.add("''")
		}
		$$ = &struct{from Ident; to Ident}{
			from: Ident{
				Name: $3.Value,
				NamePos: start,
			},
			to: *$1.(*Ident),
		}
	}

parameters_opt:
	{
		$$ = nil
	}
|	parameters comma_opt
	{
		$$ = $1
	}

parameters_type_opt:
	{
		$$ = nil
	}
|	parameters_type comma_opt
	{
		$$ = $1
	}

parameters:
	parameter
	{
		$$ = []Expr{$1}
	}
|	parameters ',' parameter
	{
		$$ = append($1, $3)
	}

// Parameters with optional type annotations
parameters_type:
	parameter_type
	{
		$$ = []Expr{$1}
	}
|	parameters_type ',' parameter_type
	{
		$$ = append($1, $3)
	}

parameter:
	ident
|	ident '=' test
	{
		$$ = binary($1, $2, $<tok>2, $3)
	}
|	'*' ident
	{
		$$ = unary($1, $<tok>1, $2)
	}
|	'*'
	{
		$$ = unary($1, $<tok>1, nil)
	}
|	_STAR_STAR ident
	{
		$$ = unary($1, $<tok>1, $2)
	}

// Parameter with optional type annotation
parameter_type:
	parameter
|
	ident ':' test
	{
		$$ = typed($1, $3)
	}
|	ident ':' test '=' test
	{
		$$ = binary(typed($1, $3), $4, $<tok>4, $5)
	}
|	'*' ident ':' test
	{
		$$ = unary($1, $<tok>1, typed($2, $4))
	}
|	_STAR_STAR ident ':' test
	{
		$$ = unary($1, $<tok>1, typed($2, $4))
	}

expr:
	test %prec ShiftInstead
|	expr ',' test
	{
		tuple, ok := $1.(*TupleExpr)
		if !ok || !tuple.NoBrackets {
			tuple = &TupleExpr{
				List: []Expr{$1},
				NoBrackets: true,
				ForceCompact: true,
				ForceMultiLine: false,
			}
		}
		tuple.List = append(tuple.List, $3)
		$$ = tuple
	}

expr_opt:
	{
		$$ = nil
	}
|	expr

test:
	primary_expr
|	_LAMBDA parameters_opt ':' expr
	{
		$$ = &LambdaExpr{
			Function: Function{
				StartPos: $1,
				Params: $2,
				Body: []Expr{$4},
			},
		}
	}
|	_NOT test %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	'-' test  %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	'+' test  %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	'~' test  %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	test '*' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '%' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '/' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _INT_DIV test { $$ = binary($1, $2, $<tok>2, $3) }
|	test '+' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '-' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '<' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '>' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _EQ test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _LE test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _NE test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _GE test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _IN test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _NOT _IN test { $$ = binary($1, $2, "not in", $4) }
|	test _OR test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _AND test     { $$ = binary($1, $2, $<tok>2, $3) }
|	test '|' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '&' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test '^' test      { $$ = binary($1, $2, $<tok>2, $3) }
|	test _BIT_LSH test { $$ = binary($1, $2, $<tok>2, $3) }
|	test _BIT_RSH test { $$ = binary($1, $2, $<tok>2, $3) }
|	test _IS test
	{
		if b, ok := $3.(*UnaryExpr); ok && b.Op == "not" {
			$$ = binary($1, $2, "is not", b.X)
		} else {
			$$ = binary($1, $2, $<tok>2, $3)
		}
	}
|	test _IF test _ELSE test
	{
		$$ = &ConditionalExpr{
			Then: $1,
			IfStart: $2,
			Test: $3,
			ElseStart: $4,
			Else: $5,
		}
	}

tests:
	test
	{
		$$ = []Expr{$1}
	}
|	tests commas test
	{
		$$ = append($1, $3)
	}

test_opt:
	{
		$$ = nil
	}
|	test

tests_opt:
	{
		$$, $<comma>$ = nil, Position{}
	}
|	tests commas_opt
	{
		$$, $<comma>$ = $1, $2
	}


// comma_opt is an optional comma. If the comma is present,
// the rule's value is the position of the comma. Otherwise
// the rule's value is the zero position. Tracking this
// lets us distinguish (x) and (x,).
comma_opt:
	{
		$$ = Position{}
	}
|	','

// commas allows us to treat multiple consecutive commas as if they are a single
// comma token. This is a syntax error in bazel, but a common user error, so it
// is convenient to automatically fix it.
commas:
  ','
| commas ','
  {
    $$ = $1
  }

// commas_opt is the one-or-more comma equivalent of comma_opt, and is used
// where trailing commas have some significance. Like commas they squash down
// to a single comma if present to fix a common user error.
commas_opt:
	{
		$$ = Position{}
	}
|	commas


keyvalue:
	test ':' test  {
		$$ = &KeyValueExpr{
			Key: $1,
			Colon: $2,
			Value: $3,
		}
	}

keyvalues_no_comma:
	keyvalue
	{
		$$ = []*KeyValueExpr{$1}
	}
|	keyvalues_no_comma commas keyvalue
	{
		$$ = append($1, $3)
	}

keyvalues:
	{
		$$ = nil
	}
|	keyvalues_no_comma
	{
		$$ = $1
	}
|	keyvalues_no_comma commas
	{
		$$ = $1
	}

loop_vars:
	primary_expr
|	loop_vars ',' primary_expr
	{
		tuple, ok := $1.(*TupleExpr)
		if !ok || !tuple.NoBrackets {
			tuple = &TupleExpr{
				List: []Expr{$1},
				NoBrackets: true,
				ForceCompact: true,
				ForceMultiLine: false,
			}
		}
		tuple.List = append(tuple.List, $3)
		$$ = tuple
	}

string:
	_STRING
	{
		$$ = &StringExpr{
			Start: $1,
			Value: $<str>1,
			TripleQuote: $<triple>1,
			End: $1.add($<tok>1),
			Token: $<tok>1,
		}
	}

ident:
	_IDENT
	{
		$$ = &Ident{NamePos: $1, Name: $<tok>1}
	}

number:
	_INT '.' _INT
	{
		$$ = &LiteralExpr{Start: $1, Token: $<tok>1 + "." + $<tok>3}
	}
|	_INT '.'
	{
		$$ = &LiteralExpr{Start: $1, Token: $<tok>1 + "."}
	}
|	'.' _INT
	{
		$$ = &LiteralExpr{Start: $1, Token: "." + $<tok>2}
	}
|	_INT %prec ShiftInstead
	{
		$$ = &LiteralExpr{Start: $1, Token: $<tok>1}
	}

for_clause:
	_FOR loop_vars _IN test
	{
		$$ = &ForClause{
			For: $1,
			Vars: $2,
			In: $3,
			X: $4,
		}
	}

for_clause_with_if_clauses_opt:
	for_clause
	{
		$$ = []Expr{$1}
	}
|	for_clause_with_if_clauses_opt _IF test
	{
		$$ = append($1, &IfClause{
			If: $2,
			Cond: $3,
		})
	}

for_clauses_with_if_clauses_opt:
	for_clause_with_if_clauses_opt
	{
		$$ = $1
	}
|	for_clauses_with_if_clauses_opt for_clause_with_if_clauses_opt
	{
		$$ = append($1, $2...)
	}

%%

// Go helper code.

// unary returns a unary expression with the given
// position, operator, and subexpression.
func unary(pos Position, op string, x Expr) Expr {
	return &UnaryExpr{
		OpStart: pos,
		Op:      op,
		X:       x,
	}
}

// binary returns a binary expression with the given
// operands, position, and operator.
func binary(x Expr, pos Position, op string, y Expr) Expr {
	_, xend := x.Span()
	ystart, _ := y.Span()

	switch op {
	case "=", "+=", "-=", "*=", "/=", "//=", "%=", "&=", "|=", "^=", "<<=", ">>=":
		return &AssignExpr{
			LHS:       x,
			OpPos:     pos,
			Op:        op,
			LineBreak: xend.Line < ystart.Line,
			RHS:       y,
		}
	}

	return &BinaryExpr{
		X:         x,
		OpStart:   pos,
		Op:        op,
		LineBreak: xend.Line < ystart.Line,
		Y:         y,
	}
}

// typed returns a TypedIdent expression
func typed(x, y Expr) *TypedIdent {
	return &TypedIdent{
		Ident: x.(*Ident),
		Type:  y,
	}
}

// isSimpleExpression returns whether an expression is simple and allowed to exist in
// compact forms of sequences.
// The formal criteria are the following: an expression is considered simple if it's
// a literal (variable, string or a number), a literal with a unary operator or an empty sequence.
func isSimpleExpression(expr *Expr) bool {
	switch x := (*expr).(type) {
	case *LiteralExpr, *StringExpr, *Ident:
		return true
	case *UnaryExpr:
		_, literal := x.X.(*LiteralExpr)
		_, ident := x.X.(*Ident)
		return literal || ident
	case *ListExpr:
		return len(x.List) == 0
	case *TupleExpr:
		return len(x.List) == 0
	case *DictExpr:
		return len(x.List) == 0
	case *SetExpr:
		return len(x.List) == 0
	default:
		return false
	}
}

// forceCompact returns the setting for the ForceCompact field for a call or tuple.
//
// NOTE 1: The field is called ForceCompact, not ForceSingleLine,
// because it only affects the formatting associated with the call or tuple syntax,
// not the formatting of the arguments. For example:
//
//	call([
//		1,
//		2,
//		3,
//	])
//
// is still a compact call even though it runs on multiple lines.
//
// In contrast the multiline form puts a linebreak after the (.
//
//	call(
//		[
//			1,
//			2,
//			3,
//		],
//	)
//
// NOTE 2: Because of NOTE 1, we cannot use start and end on the
// same line as a signal for compact mode: the formatting of an
// embedded list might move the end to a different line, which would
// then look different on rereading and cause buildifier not to be
// idempotent. Instead, we have to look at properties guaranteed
// to be preserved by the reformatting, namely that the opening
// paren and the first expression are on the same line and that
// each subsequent expression begins on the same line as the last
// one ended (no line breaks after comma).
func forceCompact(start Position, list []Expr, end Position) bool {
	if len(list) <= 1 {
		// The call or tuple will probably be compact anyway; don't force it.
		return false
	}

	// If there are any named arguments or non-string, non-literal
	// arguments, cannot force compact mode.
	line := start.Line
	for _, x := range list {
		start, end := x.Span()
		if start.Line != line {
			return false
		}
		line = end.Line
		if !isSimpleExpression(&x) {
			return false
		}
	}
	return end.Line == line
}

// forceMultiLine returns the setting for the ForceMultiLine field.
func forceMultiLine(start Position, list []Expr, end Position) bool {
	if len(list) > 1 {
		// The call will be multiline anyway, because it has multiple elements. Don't force it.
		return false
	}

	if len(list) == 0 {
		// Empty list: use position of brackets.
		return start.Line != end.Line
	}

	// Single-element list.
	// Check whether opening bracket is on different line than beginning of
	// element, or closing bracket is on different line than end of element.
	elemStart, elemEnd := list[0].Span()
	return start.Line != elemStart.Line || end.Line != elemEnd.Line
}

// forceMultiLineComprehension returns the setting for the ForceMultiLine field for a comprehension.
func forceMultiLineComprehension(start Position, expr Expr, clauses []Expr, end Position) bool {
	// Return true if there's at least one line break between start, expr, each clause, and end
	exprStart, exprEnd := expr.Span()
	if start.Line != exprStart.Line {
		return true
	}
	previousEnd := exprEnd
	for _, clause := range clauses {
		clauseStart, clauseEnd := clause.Span()
		if previousEnd.Line != clauseStart.Line {
			return true
		}
		previousEnd = clauseEnd
	}
	return previousEnd.Line != end.Line
}

// extractTrailingComments extracts trailing comments of an indented block starting with the first
// comment line with indentation less than the block indentation.
// The comments can either belong to CommentBlock statements or to the last non-comment statement
// as After-comments.
func extractTrailingComments(stmt Expr) []Expr {
	body := getLastBody(stmt)
	var comments []Expr
	if body != nil && len(*body) > 0 {
		// Get the current indentation level
		start, _ := (*body)[0].Span()
		indentation := start.LineRune

		// Find the last non-comment statement
		lastNonCommentIndex := -1
		for i, stmt := range *body {
			if _, ok := stmt.(*CommentBlock); !ok {
				lastNonCommentIndex = i
			}
		}
		if lastNonCommentIndex == -1 {
			return comments
		}

		// Iterate over the trailing comments, find the first comment line that's not indented enough,
		// dedent it and all the following comments.
		for i := lastNonCommentIndex; i < len(*body); i++ {
			stmt := (*body)[i]
			if comment := extractDedentedComment(stmt, indentation); comment != nil {
				// This comment and all the following CommentBlock statements are to be extracted.
				comments = append(comments, comment)
				comments = append(comments, (*body)[i+1:]...)
				*body = (*body)[:i+1]
				// If the current statement is a CommentBlock statement without any comment lines
				// it should be removed too.
				if i > lastNonCommentIndex && len(stmt.Comment().After) == 0 {
					*body = (*body)[:i]
				}
			}
		}
  }
  return comments
}

// extractDedentedComment extract the first comment line from `stmt` which indentation is smaller
// than `indentation`, and all following comment lines, and returns them in a newly created
// CommentBlock statement.
func extractDedentedComment(stmt Expr, indentation int) Expr {
	for i, line := range stmt.Comment().After {
		// line.Start.LineRune == 0 can't exist in parsed files, it indicates that the comment line
		// has been added by an AST modification. Don't take such lines into account.
		if line.Start.LineRune > 0 && line.Start.LineRune < indentation {
			// This and all the following lines should be dedented
			cb := &CommentBlock{
				Start: line.Start,
				Comments: Comments{After: stmt.Comment().After[i:]},
			}
			stmt.Comment().After = stmt.Comment().After[:i]
			return cb
		}
	}
	return nil
}

// getLastBody returns the last body of a block statement (the only body for For- and DefStmt
// objects, the last in a if-elif-else chain
func getLastBody(stmt Expr) *[]Expr {
	switch block := stmt.(type) {
	case *DefStmt:
		return &block.Body
	case *ForStmt:
		return &block.Body
	case *IfStmt:
		if len(block.False) == 0 {
			return &block.True
		} else if len(block.False) == 1 {
			if next, ok := block.False[0].(*IfStmt); ok {
				// Recursively find the last block of the chain
				return getLastBody(next)
			}
		}
		return &block.False
	}
	return nil
}
