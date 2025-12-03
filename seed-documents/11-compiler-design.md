# Modern Compiler Design: From Source to Machine Code

## Abstract

This comprehensive treatise examines the architecture and implementation of modern compilers, covering lexical analysis, parsing, semantic analysis, intermediate representations, optimization techniques, and code generation. We explore both classical compiler construction techniques and contemporary approaches including just-in-time compilation, link-time optimization, and profile-guided optimization. The document includes detailed algorithms, data structures, and implementation considerations for building production-quality compilers.

## 1. Introduction to Compiler Architecture

### 1.1 The Compilation Pipeline

A compiler transforms source code written in a high-level programming language into executable machine code or an intermediate representation. The classical compilation pipeline consists of several distinct phases:

```
Source Code
    │
    ▼
┌─────────────────┐
│ Lexical Analysis│  → Tokens
│   (Scanner)     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Syntax Analysis │  → Abstract Syntax Tree (AST)
│    (Parser)     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│Semantic Analysis│  → Annotated AST + Symbol Table
│ (Type Checker)  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   IR Generation │  → Intermediate Representation
│                 │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Optimization   │  → Optimized IR
│    Passes       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Code Generation │  → Assembly / Machine Code
│                 │
└────────┬────────┘
         │
         ▼
    Executable
```

### 1.2 Compiler vs. Interpreter

While compilers translate entire programs before execution, interpreters execute source code directly. Modern language implementations often combine both approaches:

**Ahead-of-Time (AOT) Compilation**: Traditional compilation where the entire program is compiled before execution. Examples include C, C++, Rust, and Go.

**Just-in-Time (JIT) Compilation**: Code is compiled during program execution, allowing for runtime optimizations based on actual program behavior. Examples include Java HotSpot, V8 JavaScript engine, and PyPy.

**Bytecode Interpretation with JIT**: Programs are first compiled to bytecode, which is then interpreted or JIT-compiled. Examples include JVM, CLR, and CPython with potential JIT.

## 2. Lexical Analysis

### 2.1 The Role of the Lexer

The lexer (scanner) transforms a stream of characters into a stream of tokens. Each token represents a meaningful unit of the source language:

```
Token Categories:
├── Keywords: if, else, while, for, return, class, ...
├── Identifiers: variable names, function names, ...
├── Literals:
│   ├── Integer: 42, 0xFF, 0b1010
│   ├── Float: 3.14, 2.5e-10
│   ├── String: "hello", 'c'
│   └── Boolean: true, false
├── Operators: +, -, *, /, ==, !=, &&, ||, ...
├── Delimiters: (, ), {, }, [, ], ;, ,, ...
└── Special: EOF, NEWLINE, INDENT, DEDENT
```

### 2.2 Regular Expressions and Finite Automata

Lexers are typically implemented using finite automata derived from regular expressions:

**Regular Expression to NFA (Thompson's Construction)**:

```
Base cases:
- ε (empty): ─○─ε─○─
- a (char):  ─○─a─○─

Inductive cases:
- AB (concatenation): ─○─A─○─ε─○─B─○─
- A|B (alternation):
       ┌─ε─○─A─○─ε─┐
    ─○─┤           ├─○─
       └─ε─○─B─○─ε─┘
- A* (Kleene star):
         ┌────ε────┐
         │    ↓    │
    ─○─ε─○─A─○─ε─○─
         │    ↑    │
         └────ε────┘
```

**NFA to DFA (Subset Construction)**:

```python
def nfa_to_dfa(nfa):
    """Convert NFA to DFA using subset construction."""
    dfa_states = {}
    dfa_transitions = {}
    dfa_accepting = set()

    # Compute epsilon closure of start state
    start_closure = epsilon_closure(nfa, {nfa.start})
    unmarked = [frozenset(start_closure)]
    dfa_states[frozenset(start_closure)] = 0
    state_counter = 1

    while unmarked:
        current = unmarked.pop()
        current_id = dfa_states[current]

        # Check if this DFA state is accepting
        if current & nfa.accepting:
            dfa_accepting.add(current_id)

        # Process each input symbol
        for symbol in nfa.alphabet:
            # Compute move and epsilon closure
            next_states = set()
            for state in current:
                if (state, symbol) in nfa.transitions:
                    next_states |= nfa.transitions[(state, symbol)]
            next_closure = epsilon_closure(nfa, next_states)

            if not next_closure:
                continue

            next_frozen = frozenset(next_closure)

            if next_frozen not in dfa_states:
                dfa_states[next_frozen] = state_counter
                state_counter += 1
                unmarked.append(next_frozen)

            dfa_transitions[(current_id, symbol)] = dfa_states[next_frozen]

    return DFA(dfa_states, dfa_transitions, 0, dfa_accepting)

def epsilon_closure(nfa, states):
    """Compute epsilon closure of a set of NFA states."""
    closure = set(states)
    worklist = list(states)

    while worklist:
        state = worklist.pop()
        if (state, 'ε') in nfa.transitions:
            for next_state in nfa.transitions[(state, 'ε')]:
                if next_state not in closure:
                    closure.add(next_state)
                    worklist.append(next_state)

    return closure
```

### 2.3 Lexer Implementation

A practical lexer implementation with error recovery:

```python
from dataclasses import dataclass
from enum import Enum, auto
from typing import Iterator, Optional
import re

class TokenType(Enum):
    # Literals
    INTEGER = auto()
    FLOAT = auto()
    STRING = auto()
    IDENTIFIER = auto()

    # Keywords
    IF = auto()
    ELSE = auto()
    WHILE = auto()
    FOR = auto()
    RETURN = auto()
    FUNCTION = auto()
    CLASS = auto()
    LET = auto()
    CONST = auto()
    TRUE = auto()
    FALSE = auto()
    NULL = auto()

    # Operators
    PLUS = auto()
    MINUS = auto()
    STAR = auto()
    SLASH = auto()
    PERCENT = auto()
    EQUALS = auto()
    EQUALS_EQUALS = auto()
    BANG = auto()
    BANG_EQUALS = auto()
    LESS = auto()
    LESS_EQUALS = auto()
    GREATER = auto()
    GREATER_EQUALS = auto()
    AND_AND = auto()
    OR_OR = auto()

    # Delimiters
    LPAREN = auto()
    RPAREN = auto()
    LBRACE = auto()
    RBRACE = auto()
    LBRACKET = auto()
    RBRACKET = auto()
    COMMA = auto()
    DOT = auto()
    SEMICOLON = auto()
    COLON = auto()
    ARROW = auto()

    # Special
    NEWLINE = auto()
    EOF = auto()
    ERROR = auto()

@dataclass
class Token:
    type: TokenType
    value: str
    line: int
    column: int

    def __repr__(self):
        return f"Token({self.type.name}, {self.value!r}, {self.line}:{self.column})"

@dataclass
class SourceLocation:
    line: int
    column: int
    offset: int

class Lexer:
    KEYWORDS = {
        'if': TokenType.IF,
        'else': TokenType.ELSE,
        'while': TokenType.WHILE,
        'for': TokenType.FOR,
        'return': TokenType.RETURN,
        'function': TokenType.FUNCTION,
        'class': TokenType.CLASS,
        'let': TokenType.LET,
        'const': TokenType.CONST,
        'true': TokenType.TRUE,
        'false': TokenType.FALSE,
        'null': TokenType.NULL,
    }

    SINGLE_CHAR_TOKENS = {
        '+': TokenType.PLUS,
        '-': TokenType.MINUS,
        '*': TokenType.STAR,
        '/': TokenType.SLASH,
        '%': TokenType.PERCENT,
        '(': TokenType.LPAREN,
        ')': TokenType.RPAREN,
        '{': TokenType.LBRACE,
        '}': TokenType.RBRACE,
        '[': TokenType.LBRACKET,
        ']': TokenType.RBRACKET,
        ',': TokenType.COMMA,
        '.': TokenType.DOT,
        ';': TokenType.SEMICOLON,
        ':': TokenType.COLON,
    }

    def __init__(self, source: str):
        self.source = source
        self.pos = 0
        self.line = 1
        self.column = 1
        self.errors: list[str] = []

    def peek(self, offset: int = 0) -> Optional[str]:
        pos = self.pos + offset
        if pos < len(self.source):
            return self.source[pos]
        return None

    def advance(self) -> Optional[str]:
        if self.pos >= len(self.source):
            return None
        char = self.source[self.pos]
        self.pos += 1
        if char == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        return char

    def skip_whitespace(self):
        while self.peek() in (' ', '\t', '\r'):
            self.advance()

    def skip_comment(self) -> bool:
        if self.peek() == '/' and self.peek(1) == '/':
            while self.peek() and self.peek() != '\n':
                self.advance()
            return True
        if self.peek() == '/' and self.peek(1) == '*':
            self.advance()  # /
            self.advance()  # *
            while self.peek():
                if self.peek() == '*' and self.peek(1) == '/':
                    self.advance()  # *
                    self.advance()  # /
                    return True
                self.advance()
            self.errors.append(f"Unterminated block comment at {self.line}:{self.column}")
            return True
        return False

    def scan_string(self) -> Token:
        start_line = self.line
        start_column = self.column
        quote = self.advance()  # Opening quote
        value = []

        while self.peek() and self.peek() != quote:
            if self.peek() == '\n':
                self.errors.append(f"Unterminated string at {start_line}:{start_column}")
                break
            if self.peek() == '\\':
                self.advance()
                escape_char = self.advance()
                escape_sequences = {
                    'n': '\n', 't': '\t', 'r': '\r',
                    '\\': '\\', '"': '"', "'": "'"
                }
                if escape_char in escape_sequences:
                    value.append(escape_sequences[escape_char])
                else:
                    value.append(escape_char)
            else:
                value.append(self.advance())

        if self.peek() == quote:
            self.advance()  # Closing quote

        return Token(TokenType.STRING, ''.join(value), start_line, start_column)

    def scan_number(self) -> Token:
        start_line = self.line
        start_column = self.column
        value = []
        is_float = False

        # Handle hex, octal, binary
        if self.peek() == '0':
            value.append(self.advance())
            if self.peek() in ('x', 'X'):
                value.append(self.advance())
                while self.peek() and self.peek() in '0123456789abcdefABCDEF':
                    value.append(self.advance())
                return Token(TokenType.INTEGER, ''.join(value), start_line, start_column)
            elif self.peek() in ('b', 'B'):
                value.append(self.advance())
                while self.peek() and self.peek() in '01':
                    value.append(self.advance())
                return Token(TokenType.INTEGER, ''.join(value), start_line, start_column)
            elif self.peek() in ('o', 'O'):
                value.append(self.advance())
                while self.peek() and self.peek() in '01234567':
                    value.append(self.advance())
                return Token(TokenType.INTEGER, ''.join(value), start_line, start_column)

        # Decimal number
        while self.peek() and self.peek().isdigit():
            value.append(self.advance())

        # Decimal point
        if self.peek() == '.' and self.peek(1) and self.peek(1).isdigit():
            is_float = True
            value.append(self.advance())
            while self.peek() and self.peek().isdigit():
                value.append(self.advance())

        # Exponent
        if self.peek() in ('e', 'E'):
            is_float = True
            value.append(self.advance())
            if self.peek() in ('+', '-'):
                value.append(self.advance())
            while self.peek() and self.peek().isdigit():
                value.append(self.advance())

        token_type = TokenType.FLOAT if is_float else TokenType.INTEGER
        return Token(token_type, ''.join(value), start_line, start_column)

    def scan_identifier(self) -> Token:
        start_line = self.line
        start_column = self.column
        value = []

        while self.peek() and (self.peek().isalnum() or self.peek() == '_'):
            value.append(self.advance())

        text = ''.join(value)
        token_type = self.KEYWORDS.get(text, TokenType.IDENTIFIER)
        return Token(token_type, text, start_line, start_column)

    def scan_token(self) -> Token:
        self.skip_whitespace()
        while self.skip_comment():
            self.skip_whitespace()

        if self.peek() is None:
            return Token(TokenType.EOF, '', self.line, self.column)

        start_line = self.line
        start_column = self.column
        char = self.peek()

        # Newline
        if char == '\n':
            self.advance()
            return Token(TokenType.NEWLINE, '\n', start_line, start_column)

        # String literals
        if char in ('"', "'"):
            return self.scan_string()

        # Numbers
        if char.isdigit():
            return self.scan_number()

        # Identifiers and keywords
        if char.isalpha() or char == '_':
            return self.scan_identifier()

        # Two-character operators
        two_char = char + (self.peek(1) or '')
        two_char_tokens = {
            '==': TokenType.EQUALS_EQUALS,
            '!=': TokenType.BANG_EQUALS,
            '<=': TokenType.LESS_EQUALS,
            '>=': TokenType.GREATER_EQUALS,
            '&&': TokenType.AND_AND,
            '||': TokenType.OR_OR,
            '->': TokenType.ARROW,
        }
        if two_char in two_char_tokens:
            self.advance()
            self.advance()
            return Token(two_char_tokens[two_char], two_char, start_line, start_column)

        # Single-character operators
        if char in self.SINGLE_CHAR_TOKENS:
            self.advance()
            return Token(self.SINGLE_CHAR_TOKENS[char], char, start_line, start_column)

        # Additional single-character tokens
        single_extra = {
            '=': TokenType.EQUALS,
            '!': TokenType.BANG,
            '<': TokenType.LESS,
            '>': TokenType.GREATER,
        }
        if char in single_extra:
            self.advance()
            return Token(single_extra[char], char, start_line, start_column)

        # Error: unexpected character
        self.advance()
        self.errors.append(f"Unexpected character '{char}' at {start_line}:{start_column}")
        return Token(TokenType.ERROR, char, start_line, start_column)

    def tokenize(self) -> Iterator[Token]:
        while True:
            token = self.scan_token()
            yield token
            if token.type == TokenType.EOF:
                break
```

## 3. Syntax Analysis (Parsing)

### 3.1 Context-Free Grammars

Parsers are built from context-free grammars (CFGs). A CFG consists of:

- **Terminals**: Tokens from the lexer
- **Non-terminals**: Syntactic categories
- **Productions**: Rules defining how non-terminals expand
- **Start symbol**: The root non-terminal

Example grammar for expressions:

```
expr     → term (('+' | '-') term)*
term     → factor (('*' | '/') factor)*
factor   → NUMBER | IDENTIFIER | '(' expr ')'
         | '-' factor
         | IDENTIFIER '(' arguments? ')'
arguments → expr (',' expr)*
```

### 3.2 Recursive Descent Parser

A recursive descent parser implements each grammar rule as a function:

```python
from dataclasses import dataclass
from typing import List, Optional, Union

# AST Node definitions
@dataclass
class NumberLiteral:
    value: float

@dataclass
class StringLiteral:
    value: str

@dataclass
class BooleanLiteral:
    value: bool

@dataclass
class NullLiteral:
    pass

@dataclass
class Identifier:
    name: str

@dataclass
class BinaryOp:
    operator: str
    left: 'Expression'
    right: 'Expression'

@dataclass
class UnaryOp:
    operator: str
    operand: 'Expression'

@dataclass
class CallExpr:
    callee: 'Expression'
    arguments: List['Expression']

@dataclass
class IndexExpr:
    object: 'Expression'
    index: 'Expression'

@dataclass
class MemberExpr:
    object: 'Expression'
    property: str

@dataclass
class AssignExpr:
    target: 'Expression'
    value: 'Expression'

@dataclass
class ConditionalExpr:
    condition: 'Expression'
    then_expr: 'Expression'
    else_expr: 'Expression'

@dataclass
class LambdaExpr:
    parameters: List[str]
    body: 'Expression'

Expression = Union[
    NumberLiteral, StringLiteral, BooleanLiteral, NullLiteral,
    Identifier, BinaryOp, UnaryOp, CallExpr, IndexExpr,
    MemberExpr, AssignExpr, ConditionalExpr, LambdaExpr
]

# Statement AST nodes
@dataclass
class ExpressionStmt:
    expression: Expression

@dataclass
class VarDecl:
    name: str
    initializer: Optional[Expression]
    is_const: bool

@dataclass
class BlockStmt:
    statements: List['Statement']

@dataclass
class IfStmt:
    condition: Expression
    then_branch: 'Statement'
    else_branch: Optional['Statement']

@dataclass
class WhileStmt:
    condition: Expression
    body: 'Statement'

@dataclass
class ForStmt:
    initializer: Optional['Statement']
    condition: Optional[Expression]
    increment: Optional[Expression]
    body: 'Statement'

@dataclass
class ReturnStmt:
    value: Optional[Expression]

@dataclass
class FunctionDecl:
    name: str
    parameters: List[str]
    body: BlockStmt

@dataclass
class ClassDecl:
    name: str
    superclass: Optional[str]
    methods: List[FunctionDecl]

Statement = Union[
    ExpressionStmt, VarDecl, BlockStmt, IfStmt, WhileStmt,
    ForStmt, ReturnStmt, FunctionDecl, ClassDecl
]

class ParseError(Exception):
    def __init__(self, message: str, token: Token):
        super().__init__(message)
        self.token = token

class Parser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.current = 0
        self.errors: List[str] = []

    def peek(self) -> Token:
        return self.tokens[self.current]

    def previous(self) -> Token:
        return self.tokens[self.current - 1]

    def is_at_end(self) -> bool:
        return self.peek().type == TokenType.EOF

    def advance(self) -> Token:
        if not self.is_at_end():
            self.current += 1
        return self.previous()

    def check(self, *types: TokenType) -> bool:
        if self.is_at_end():
            return False
        return self.peek().type in types

    def match(self, *types: TokenType) -> bool:
        if self.check(*types):
            self.advance()
            return True
        return False

    def consume(self, type: TokenType, message: str) -> Token:
        if self.check(type):
            return self.advance()
        raise ParseError(message, self.peek())

    def synchronize(self):
        """Error recovery: skip to next statement boundary."""
        self.advance()
        while not self.is_at_end():
            if self.previous().type == TokenType.SEMICOLON:
                return
            if self.peek().type in (
                TokenType.CLASS, TokenType.FUNCTION, TokenType.LET,
                TokenType.CONST, TokenType.FOR, TokenType.IF,
                TokenType.WHILE, TokenType.RETURN
            ):
                return
            self.advance()

    # Expression parsing with precedence climbing
    def parse_expression(self) -> Expression:
        return self.parse_assignment()

    def parse_assignment(self) -> Expression:
        expr = self.parse_conditional()

        if self.match(TokenType.EQUALS):
            value = self.parse_assignment()
            if isinstance(expr, (Identifier, IndexExpr, MemberExpr)):
                return AssignExpr(expr, value)
            raise ParseError("Invalid assignment target", self.previous())

        return expr

    def parse_conditional(self) -> Expression:
        expr = self.parse_or()

        if self.match(TokenType.QUESTION) if hasattr(TokenType, 'QUESTION') else False:
            then_expr = self.parse_expression()
            self.consume(TokenType.COLON, "Expected ':' in conditional expression")
            else_expr = self.parse_conditional()
            return ConditionalExpr(expr, then_expr, else_expr)

        return expr

    def parse_or(self) -> Expression:
        expr = self.parse_and()

        while self.match(TokenType.OR_OR):
            operator = self.previous().value
            right = self.parse_and()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_and(self) -> Expression:
        expr = self.parse_equality()

        while self.match(TokenType.AND_AND):
            operator = self.previous().value
            right = self.parse_equality()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_equality(self) -> Expression:
        expr = self.parse_comparison()

        while self.match(TokenType.EQUALS_EQUALS, TokenType.BANG_EQUALS):
            operator = self.previous().value
            right = self.parse_comparison()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_comparison(self) -> Expression:
        expr = self.parse_term()

        while self.match(TokenType.LESS, TokenType.LESS_EQUALS,
                        TokenType.GREATER, TokenType.GREATER_EQUALS):
            operator = self.previous().value
            right = self.parse_term()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_term(self) -> Expression:
        expr = self.parse_factor()

        while self.match(TokenType.PLUS, TokenType.MINUS):
            operator = self.previous().value
            right = self.parse_factor()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_factor(self) -> Expression:
        expr = self.parse_unary()

        while self.match(TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            operator = self.previous().value
            right = self.parse_unary()
            expr = BinaryOp(operator, expr, right)

        return expr

    def parse_unary(self) -> Expression:
        if self.match(TokenType.BANG, TokenType.MINUS):
            operator = self.previous().value
            operand = self.parse_unary()
            return UnaryOp(operator, operand)

        return self.parse_call()

    def parse_call(self) -> Expression:
        expr = self.parse_primary()

        while True:
            if self.match(TokenType.LPAREN):
                arguments = []
                if not self.check(TokenType.RPAREN):
                    arguments.append(self.parse_expression())
                    while self.match(TokenType.COMMA):
                        arguments.append(self.parse_expression())
                self.consume(TokenType.RPAREN, "Expected ')' after arguments")
                expr = CallExpr(expr, arguments)
            elif self.match(TokenType.DOT):
                name = self.consume(TokenType.IDENTIFIER, "Expected property name").value
                expr = MemberExpr(expr, name)
            elif self.match(TokenType.LBRACKET):
                index = self.parse_expression()
                self.consume(TokenType.RBRACKET, "Expected ']' after index")
                expr = IndexExpr(expr, index)
            else:
                break

        return expr

    def parse_primary(self) -> Expression:
        if self.match(TokenType.TRUE):
            return BooleanLiteral(True)
        if self.match(TokenType.FALSE):
            return BooleanLiteral(False)
        if self.match(TokenType.NULL):
            return NullLiteral()

        if self.match(TokenType.INTEGER):
            value = self.previous().value
            if value.startswith('0x') or value.startswith('0X'):
                return NumberLiteral(float(int(value, 16)))
            elif value.startswith('0b') or value.startswith('0B'):
                return NumberLiteral(float(int(value, 2)))
            elif value.startswith('0o') or value.startswith('0O'):
                return NumberLiteral(float(int(value, 8)))
            return NumberLiteral(float(value))

        if self.match(TokenType.FLOAT):
            return NumberLiteral(float(self.previous().value))

        if self.match(TokenType.STRING):
            return StringLiteral(self.previous().value)

        if self.match(TokenType.IDENTIFIER):
            return Identifier(self.previous().value)

        if self.match(TokenType.LPAREN):
            expr = self.parse_expression()
            self.consume(TokenType.RPAREN, "Expected ')' after expression")
            return expr

        raise ParseError(f"Unexpected token: {self.peek().type}", self.peek())

    # Statement parsing
    def parse_statement(self) -> Statement:
        try:
            if self.match(TokenType.LET, TokenType.CONST):
                return self.parse_var_declaration()
            if self.match(TokenType.FUNCTION):
                return self.parse_function_declaration()
            if self.match(TokenType.CLASS):
                return self.parse_class_declaration()
            if self.match(TokenType.IF):
                return self.parse_if_statement()
            if self.match(TokenType.WHILE):
                return self.parse_while_statement()
            if self.match(TokenType.FOR):
                return self.parse_for_statement()
            if self.match(TokenType.RETURN):
                return self.parse_return_statement()
            if self.match(TokenType.LBRACE):
                return self.parse_block()
            return self.parse_expression_statement()
        except ParseError as e:
            self.errors.append(f"{e} at {e.token.line}:{e.token.column}")
            self.synchronize()
            return ExpressionStmt(NullLiteral())

    def parse_var_declaration(self) -> VarDecl:
        is_const = self.previous().type == TokenType.CONST
        name = self.consume(TokenType.IDENTIFIER, "Expected variable name").value

        initializer = None
        if self.match(TokenType.EQUALS):
            initializer = self.parse_expression()

        self.consume(TokenType.SEMICOLON, "Expected ';' after variable declaration")
        return VarDecl(name, initializer, is_const)

    def parse_function_declaration(self) -> FunctionDecl:
        name = self.consume(TokenType.IDENTIFIER, "Expected function name").value
        self.consume(TokenType.LPAREN, "Expected '(' after function name")

        parameters = []
        if not self.check(TokenType.RPAREN):
            parameters.append(self.consume(TokenType.IDENTIFIER, "Expected parameter name").value)
            while self.match(TokenType.COMMA):
                parameters.append(self.consume(TokenType.IDENTIFIER, "Expected parameter name").value)

        self.consume(TokenType.RPAREN, "Expected ')' after parameters")
        self.consume(TokenType.LBRACE, "Expected '{' before function body")
        body = self.parse_block()

        return FunctionDecl(name, parameters, body)

    def parse_class_declaration(self) -> ClassDecl:
        name = self.consume(TokenType.IDENTIFIER, "Expected class name").value

        superclass = None
        # Could add 'extends' keyword handling here

        self.consume(TokenType.LBRACE, "Expected '{' before class body")

        methods = []
        while not self.check(TokenType.RBRACE) and not self.is_at_end():
            self.match(TokenType.FUNCTION)  # Optional 'function' keyword in class
            methods.append(self.parse_function_declaration())

        self.consume(TokenType.RBRACE, "Expected '}' after class body")
        return ClassDecl(name, superclass, methods)

    def parse_if_statement(self) -> IfStmt:
        self.consume(TokenType.LPAREN, "Expected '(' after 'if'")
        condition = self.parse_expression()
        self.consume(TokenType.RPAREN, "Expected ')' after condition")

        then_branch = self.parse_statement()
        else_branch = None
        if self.match(TokenType.ELSE):
            else_branch = self.parse_statement()

        return IfStmt(condition, then_branch, else_branch)

    def parse_while_statement(self) -> WhileStmt:
        self.consume(TokenType.LPAREN, "Expected '(' after 'while'")
        condition = self.parse_expression()
        self.consume(TokenType.RPAREN, "Expected ')' after condition")
        body = self.parse_statement()

        return WhileStmt(condition, body)

    def parse_for_statement(self) -> ForStmt:
        self.consume(TokenType.LPAREN, "Expected '(' after 'for'")

        initializer = None
        if self.match(TokenType.SEMICOLON):
            pass
        elif self.match(TokenType.LET, TokenType.CONST):
            initializer = self.parse_var_declaration()
        else:
            initializer = self.parse_expression_statement()

        condition = None
        if not self.check(TokenType.SEMICOLON):
            condition = self.parse_expression()
        self.consume(TokenType.SEMICOLON, "Expected ';' after loop condition")

        increment = None
        if not self.check(TokenType.RPAREN):
            increment = self.parse_expression()
        self.consume(TokenType.RPAREN, "Expected ')' after for clauses")

        body = self.parse_statement()

        return ForStmt(initializer, condition, increment, body)

    def parse_return_statement(self) -> ReturnStmt:
        value = None
        if not self.check(TokenType.SEMICOLON):
            value = self.parse_expression()
        self.consume(TokenType.SEMICOLON, "Expected ';' after return value")
        return ReturnStmt(value)

    def parse_block(self) -> BlockStmt:
        statements = []
        while not self.check(TokenType.RBRACE) and not self.is_at_end():
            # Skip newlines in block
            while self.match(TokenType.NEWLINE):
                pass
            if not self.check(TokenType.RBRACE):
                statements.append(self.parse_statement())

        self.consume(TokenType.RBRACE, "Expected '}' after block")
        return BlockStmt(statements)

    def parse_expression_statement(self) -> ExpressionStmt:
        expr = self.parse_expression()
        self.consume(TokenType.SEMICOLON, "Expected ';' after expression")
        return ExpressionStmt(expr)

    def parse_program(self) -> List[Statement]:
        statements = []
        while not self.is_at_end():
            # Skip newlines at top level
            while self.match(TokenType.NEWLINE):
                pass
            if not self.is_at_end():
                statements.append(self.parse_statement())
        return statements
```

## 4. Semantic Analysis

### 4.1 Symbol Tables

Symbol tables track identifiers and their attributes throughout compilation:

```python
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any
from enum import Enum, auto

class SymbolKind(Enum):
    VARIABLE = auto()
    FUNCTION = auto()
    PARAMETER = auto()
    CLASS = auto()
    METHOD = auto()
    FIELD = auto()

@dataclass
class Symbol:
    name: str
    kind: SymbolKind
    type: 'Type'
    scope_level: int
    is_const: bool = False
    is_initialized: bool = False
    definition_location: Optional[SourceLocation] = None
    attributes: Dict[str, Any] = field(default_factory=dict)

class SymbolTable:
    def __init__(self, parent: Optional['SymbolTable'] = None, name: str = "global"):
        self.parent = parent
        self.name = name
        self.symbols: Dict[str, Symbol] = {}
        self.children: List['SymbolTable'] = []
        self.scope_level = parent.scope_level + 1 if parent else 0

        if parent:
            parent.children.append(self)

    def define(self, symbol: Symbol) -> bool:
        """Define a symbol in current scope. Returns False if already defined."""
        if symbol.name in self.symbols:
            return False
        symbol.scope_level = self.scope_level
        self.symbols[symbol.name] = symbol
        return True

    def resolve(self, name: str) -> Optional[Symbol]:
        """Look up a symbol, checking parent scopes."""
        if name in self.symbols:
            return self.symbols[name]
        if self.parent:
            return self.parent.resolve(name)
        return None

    def resolve_local(self, name: str) -> Optional[Symbol]:
        """Look up a symbol in current scope only."""
        return self.symbols.get(name)

    def enter_scope(self, name: str = "block") -> 'SymbolTable':
        """Create and return a new child scope."""
        return SymbolTable(parent=self, name=name)

    def exit_scope(self) -> Optional['SymbolTable']:
        """Return to parent scope."""
        return self.parent
```

### 4.2 Type System

A type system for semantic analysis:

```python
from dataclasses import dataclass
from typing import List, Optional, Dict, Tuple
from abc import ABC, abstractmethod

class Type(ABC):
    @abstractmethod
    def __eq__(self, other: object) -> bool:
        pass

    @abstractmethod
    def __hash__(self) -> int:
        pass

    @abstractmethod
    def is_assignable_from(self, other: 'Type') -> bool:
        """Check if a value of 'other' type can be assigned to this type."""
        pass

@dataclass(frozen=True)
class PrimitiveType(Type):
    name: str

    def __eq__(self, other: object) -> bool:
        return isinstance(other, PrimitiveType) and self.name == other.name

    def __hash__(self) -> int:
        return hash(('primitive', self.name))

    def is_assignable_from(self, other: Type) -> bool:
        if self == other:
            return True
        # Numeric promotions
        if self.name == 'float' and isinstance(other, PrimitiveType) and other.name == 'int':
            return True
        return False

    def __repr__(self) -> str:
        return self.name

# Built-in primitive types
INT_TYPE = PrimitiveType('int')
FLOAT_TYPE = PrimitiveType('float')
BOOL_TYPE = PrimitiveType('bool')
STRING_TYPE = PrimitiveType('string')
VOID_TYPE = PrimitiveType('void')
NULL_TYPE = PrimitiveType('null')
ANY_TYPE = PrimitiveType('any')
NEVER_TYPE = PrimitiveType('never')

@dataclass(frozen=True)
class ArrayType(Type):
    element_type: Type

    def __eq__(self, other: object) -> bool:
        return isinstance(other, ArrayType) and self.element_type == other.element_type

    def __hash__(self) -> int:
        return hash(('array', self.element_type))

    def is_assignable_from(self, other: Type) -> bool:
        if isinstance(other, ArrayType):
            return self.element_type.is_assignable_from(other.element_type)
        return False

    def __repr__(self) -> str:
        return f"{self.element_type}[]"

@dataclass(frozen=True)
class FunctionType(Type):
    parameter_types: Tuple[Type, ...]
    return_type: Type

    def __eq__(self, other: object) -> bool:
        return (isinstance(other, FunctionType) and
                self.parameter_types == other.parameter_types and
                self.return_type == other.return_type)

    def __hash__(self) -> int:
        return hash(('function', self.parameter_types, self.return_type))

    def is_assignable_from(self, other: Type) -> bool:
        if not isinstance(other, FunctionType):
            return False
        if len(self.parameter_types) != len(other.parameter_types):
            return False
        # Contravariant parameters
        for self_param, other_param in zip(self.parameter_types, other.parameter_types):
            if not other_param.is_assignable_from(self_param):
                return False
        # Covariant return type
        return self.return_type.is_assignable_from(other.return_type)

    def __repr__(self) -> str:
        params = ', '.join(str(p) for p in self.parameter_types)
        return f"({params}) -> {self.return_type}"

@dataclass
class ClassType(Type):
    name: str
    superclass: Optional['ClassType'] = None
    fields: Dict[str, Type] = field(default_factory=dict)
    methods: Dict[str, FunctionType] = field(default_factory=dict)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, ClassType) and self.name == other.name

    def __hash__(self) -> int:
        return hash(('class', self.name))

    def is_assignable_from(self, other: Type) -> bool:
        if other == NULL_TYPE:
            return True
        if not isinstance(other, ClassType):
            return False
        # Check inheritance chain
        current: Optional[ClassType] = other
        while current is not None:
            if current.name == self.name:
                return True
            current = current.superclass
        return False

    def get_field(self, name: str) -> Optional[Type]:
        if name in self.fields:
            return self.fields[name]
        if self.superclass:
            return self.superclass.get_field(name)
        return None

    def get_method(self, name: str) -> Optional[FunctionType]:
        if name in self.methods:
            return self.methods[name]
        if self.superclass:
            return self.superclass.get_method(name)
        return None

    def __repr__(self) -> str:
        return self.name

@dataclass(frozen=True)
class UnionType(Type):
    types: Tuple[Type, ...]

    def __eq__(self, other: object) -> bool:
        return isinstance(other, UnionType) and set(self.types) == set(other.types)

    def __hash__(self) -> int:
        return hash(('union', frozenset(self.types)))

    def is_assignable_from(self, other: Type) -> bool:
        if isinstance(other, UnionType):
            return all(self.is_assignable_from(t) for t in other.types)
        return any(t.is_assignable_from(other) for t in self.types)

    def __repr__(self) -> str:
        return ' | '.join(str(t) for t in self.types)
```

### 4.3 Type Checker Implementation

```python
class TypeChecker:
    def __init__(self):
        self.symbol_table = SymbolTable()
        self.errors: List[str] = []
        self.current_function_return_type: Optional[Type] = None
        self.current_class: Optional[ClassType] = None

    def error(self, message: str, location: Optional[SourceLocation] = None):
        if location:
            self.errors.append(f"{message} at {location.line}:{location.column}")
        else:
            self.errors.append(message)

    def check_program(self, statements: List[Statement]):
        # First pass: collect class and function declarations
        for stmt in statements:
            if isinstance(stmt, ClassDecl):
                self.declare_class(stmt)
            elif isinstance(stmt, FunctionDecl):
                self.declare_function(stmt)

        # Second pass: type check everything
        for stmt in statements:
            self.check_statement(stmt)

    def declare_class(self, decl: ClassDecl):
        class_type = ClassType(decl.name, None, {}, {})

        # Handle superclass
        if decl.superclass:
            superclass_symbol = self.symbol_table.resolve(decl.superclass)
            if superclass_symbol and isinstance(superclass_symbol.type, ClassType):
                class_type.superclass = superclass_symbol.type
            else:
                self.error(f"Unknown superclass: {decl.superclass}")

        # Declare methods
        for method in decl.methods:
            param_types = tuple(ANY_TYPE for _ in method.parameters)
            method_type = FunctionType(param_types, ANY_TYPE)
            class_type.methods[method.name] = method_type

        symbol = Symbol(decl.name, SymbolKind.CLASS, class_type, 0)
        if not self.symbol_table.define(symbol):
            self.error(f"Class '{decl.name}' already defined")

    def declare_function(self, decl: FunctionDecl):
        param_types = tuple(ANY_TYPE for _ in decl.parameters)
        func_type = FunctionType(param_types, ANY_TYPE)

        symbol = Symbol(decl.name, SymbolKind.FUNCTION, func_type, 0)
        if not self.symbol_table.define(symbol):
            self.error(f"Function '{decl.name}' already defined")

    def check_statement(self, stmt: Statement):
        if isinstance(stmt, VarDecl):
            self.check_var_declaration(stmt)
        elif isinstance(stmt, FunctionDecl):
            self.check_function_declaration(stmt)
        elif isinstance(stmt, ClassDecl):
            self.check_class_declaration(stmt)
        elif isinstance(stmt, IfStmt):
            self.check_if_statement(stmt)
        elif isinstance(stmt, WhileStmt):
            self.check_while_statement(stmt)
        elif isinstance(stmt, ForStmt):
            self.check_for_statement(stmt)
        elif isinstance(stmt, ReturnStmt):
            self.check_return_statement(stmt)
        elif isinstance(stmt, BlockStmt):
            self.check_block(stmt)
        elif isinstance(stmt, ExpressionStmt):
            self.check_expression(stmt.expression)

    def check_var_declaration(self, decl: VarDecl):
        init_type = ANY_TYPE
        if decl.initializer:
            init_type = self.check_expression(decl.initializer)

        symbol = Symbol(
            decl.name, SymbolKind.VARIABLE, init_type, 0,
            is_const=decl.is_const, is_initialized=decl.initializer is not None
        )

        if not self.symbol_table.define(symbol):
            self.error(f"Variable '{decl.name}' already defined in this scope")

    def check_function_declaration(self, decl: FunctionDecl):
        # Enter function scope
        self.symbol_table = self.symbol_table.enter_scope(f"function:{decl.name}")

        # Declare parameters
        for param in decl.parameters:
            symbol = Symbol(param, SymbolKind.PARAMETER, ANY_TYPE, 0, is_initialized=True)
            self.symbol_table.define(symbol)

        # Get declared return type
        func_symbol = self.symbol_table.parent.resolve(decl.name)
        if func_symbol:
            self.current_function_return_type = func_symbol.type.return_type
        else:
            self.current_function_return_type = ANY_TYPE

        # Check body
        self.check_block(decl.body)

        # Exit function scope
        self.current_function_return_type = None
        self.symbol_table = self.symbol_table.exit_scope()

    def check_class_declaration(self, decl: ClassDecl):
        class_symbol = self.symbol_table.resolve(decl.name)
        if not class_symbol:
            return

        self.current_class = class_symbol.type

        for method in decl.methods:
            self.check_function_declaration(method)

        self.current_class = None

    def check_if_statement(self, stmt: IfStmt):
        cond_type = self.check_expression(stmt.condition)
        if cond_type != BOOL_TYPE and cond_type != ANY_TYPE:
            self.error(f"Condition must be boolean, got {cond_type}")

        self.check_statement(stmt.then_branch)
        if stmt.else_branch:
            self.check_statement(stmt.else_branch)

    def check_while_statement(self, stmt: WhileStmt):
        cond_type = self.check_expression(stmt.condition)
        if cond_type != BOOL_TYPE and cond_type != ANY_TYPE:
            self.error(f"Condition must be boolean, got {cond_type}")

        self.check_statement(stmt.body)

    def check_for_statement(self, stmt: ForStmt):
        self.symbol_table = self.symbol_table.enter_scope("for")

        if stmt.initializer:
            self.check_statement(stmt.initializer)

        if stmt.condition:
            cond_type = self.check_expression(stmt.condition)
            if cond_type != BOOL_TYPE and cond_type != ANY_TYPE:
                self.error(f"Condition must be boolean, got {cond_type}")

        if stmt.increment:
            self.check_expression(stmt.increment)

        self.check_statement(stmt.body)

        self.symbol_table = self.symbol_table.exit_scope()

    def check_return_statement(self, stmt: ReturnStmt):
        if self.current_function_return_type is None:
            self.error("Return statement outside of function")
            return

        if stmt.value:
            value_type = self.check_expression(stmt.value)
            if not self.current_function_return_type.is_assignable_from(value_type):
                self.error(f"Cannot return {value_type} from function expecting {self.current_function_return_type}")
        elif self.current_function_return_type != VOID_TYPE:
            self.error("Missing return value")

    def check_block(self, block: BlockStmt):
        for stmt in block.statements:
            self.check_statement(stmt)

    def check_expression(self, expr: Expression) -> Type:
        if isinstance(expr, NumberLiteral):
            if '.' in str(expr.value) or 'e' in str(expr.value).lower():
                return FLOAT_TYPE
            return INT_TYPE

        elif isinstance(expr, StringLiteral):
            return STRING_TYPE

        elif isinstance(expr, BooleanLiteral):
            return BOOL_TYPE

        elif isinstance(expr, NullLiteral):
            return NULL_TYPE

        elif isinstance(expr, Identifier):
            symbol = self.symbol_table.resolve(expr.name)
            if symbol is None:
                self.error(f"Undefined variable: {expr.name}")
                return ANY_TYPE
            return symbol.type

        elif isinstance(expr, BinaryOp):
            return self.check_binary_op(expr)

        elif isinstance(expr, UnaryOp):
            return self.check_unary_op(expr)

        elif isinstance(expr, CallExpr):
            return self.check_call(expr)

        elif isinstance(expr, MemberExpr):
            return self.check_member_access(expr)

        elif isinstance(expr, IndexExpr):
            return self.check_index(expr)

        elif isinstance(expr, AssignExpr):
            return self.check_assignment(expr)

        return ANY_TYPE

    def check_binary_op(self, expr: BinaryOp) -> Type:
        left_type = self.check_expression(expr.left)
        right_type = self.check_expression(expr.right)

        # Arithmetic operators
        if expr.operator in ('+', '-', '*', '/', '%'):
            if expr.operator == '+' and (left_type == STRING_TYPE or right_type == STRING_TYPE):
                return STRING_TYPE
            if left_type in (INT_TYPE, FLOAT_TYPE, ANY_TYPE) and right_type in (INT_TYPE, FLOAT_TYPE, ANY_TYPE):
                if left_type == FLOAT_TYPE or right_type == FLOAT_TYPE:
                    return FLOAT_TYPE
                return INT_TYPE
            self.error(f"Invalid operands for {expr.operator}: {left_type} and {right_type}")
            return ANY_TYPE

        # Comparison operators
        if expr.operator in ('<', '<=', '>', '>='):
            if left_type in (INT_TYPE, FLOAT_TYPE, ANY_TYPE) and right_type in (INT_TYPE, FLOAT_TYPE, ANY_TYPE):
                return BOOL_TYPE
            self.error(f"Invalid operands for {expr.operator}: {left_type} and {right_type}")
            return BOOL_TYPE

        # Equality operators
        if expr.operator in ('==', '!='):
            return BOOL_TYPE

        # Logical operators
        if expr.operator in ('&&', '||'):
            if left_type != BOOL_TYPE and left_type != ANY_TYPE:
                self.error(f"Left operand of {expr.operator} must be boolean")
            if right_type != BOOL_TYPE and right_type != ANY_TYPE:
                self.error(f"Right operand of {expr.operator} must be boolean")
            return BOOL_TYPE

        return ANY_TYPE

    def check_unary_op(self, expr: UnaryOp) -> Type:
        operand_type = self.check_expression(expr.operand)

        if expr.operator == '-':
            if operand_type in (INT_TYPE, FLOAT_TYPE, ANY_TYPE):
                return operand_type
            self.error(f"Cannot negate {operand_type}")
            return ANY_TYPE

        if expr.operator == '!':
            if operand_type != BOOL_TYPE and operand_type != ANY_TYPE:
                self.error(f"Cannot apply ! to {operand_type}")
            return BOOL_TYPE

        return ANY_TYPE

    def check_call(self, expr: CallExpr) -> Type:
        callee_type = self.check_expression(expr.callee)

        if isinstance(callee_type, FunctionType):
            if len(expr.arguments) != len(callee_type.parameter_types):
                self.error(f"Expected {len(callee_type.parameter_types)} arguments, got {len(expr.arguments)}")
            else:
                for i, (arg, param_type) in enumerate(zip(expr.arguments, callee_type.parameter_types)):
                    arg_type = self.check_expression(arg)
                    if not param_type.is_assignable_from(arg_type):
                        self.error(f"Argument {i+1}: expected {param_type}, got {arg_type}")
            return callee_type.return_type

        if callee_type == ANY_TYPE:
            for arg in expr.arguments:
                self.check_expression(arg)
            return ANY_TYPE

        self.error(f"Cannot call {callee_type}")
        return ANY_TYPE

    def check_member_access(self, expr: MemberExpr) -> Type:
        object_type = self.check_expression(expr.object)

        if isinstance(object_type, ClassType):
            field_type = object_type.get_field(expr.property)
            if field_type:
                return field_type

            method_type = object_type.get_method(expr.property)
            if method_type:
                return method_type

            self.error(f"'{object_type.name}' has no member '{expr.property}'")
            return ANY_TYPE

        if object_type == ANY_TYPE:
            return ANY_TYPE

        self.error(f"Cannot access member of {object_type}")
        return ANY_TYPE

    def check_index(self, expr: IndexExpr) -> Type:
        object_type = self.check_expression(expr.object)
        index_type = self.check_expression(expr.index)

        if isinstance(object_type, ArrayType):
            if index_type != INT_TYPE and index_type != ANY_TYPE:
                self.error(f"Array index must be integer, got {index_type}")
            return object_type.element_type

        if object_type == STRING_TYPE:
            if index_type != INT_TYPE and index_type != ANY_TYPE:
                self.error(f"String index must be integer, got {index_type}")
            return STRING_TYPE

        if object_type == ANY_TYPE:
            return ANY_TYPE

        self.error(f"Cannot index {object_type}")
        return ANY_TYPE

    def check_assignment(self, expr: AssignExpr) -> Type:
        target_type = self.check_expression(expr.target)
        value_type = self.check_expression(expr.value)

        # Check for const assignment
        if isinstance(expr.target, Identifier):
            symbol = self.symbol_table.resolve(expr.target.name)
            if symbol and symbol.is_const:
                self.error(f"Cannot assign to const variable '{expr.target.name}'")

        if not target_type.is_assignable_from(value_type) and target_type != ANY_TYPE:
            self.error(f"Cannot assign {value_type} to {target_type}")

        return target_type
```

## 5. Intermediate Representations

### 5.1 Three-Address Code

Three-address code (TAC) is a common IR where each instruction has at most three operands:

```
Types of TAC instructions:
- x = y op z     (binary operation)
- x = op y       (unary operation)
- x = y          (copy)
- goto L         (unconditional jump)
- if x goto L    (conditional jump)
- if x relop y goto L (conditional jump with comparison)
- param x        (procedure parameter)
- call p, n      (procedure call with n parameters)
- return x       (return from procedure)
- x = y[i]       (indexed load)
- x[i] = y       (indexed store)
- x = &y         (address of)
- x = *y         (pointer dereference)
- *x = y         (pointer assignment)
```

### 5.2 Static Single Assignment (SSA)

SSA form ensures each variable is assigned exactly once, simplifying many optimizations:

```
Original code:
  x = 1
  x = x + 1
  y = x * 2
  if (cond)
    x = 3
  else
    x = 4
  z = x + y

SSA form:
  x1 = 1
  x2 = x1 + 1
  y1 = x2 * 2
  if (cond)
    x3 = 3
  else
    x4 = 4
  x5 = φ(x3, x4)    // phi function
  z1 = x5 + y1
```

## 6. Optimization Techniques

### 6.1 Local Optimizations

**Constant Folding**: Evaluate constant expressions at compile time.
```
Before: x = 3 + 4 * 2
After:  x = 11
```

**Constant Propagation**: Replace variables with known constant values.
```
Before: x = 5; y = x + 3
After:  x = 5; y = 8
```

**Dead Code Elimination**: Remove code that has no effect.
```
Before: x = 5; x = 10; return x
After:  x = 10; return x
```

**Common Subexpression Elimination**: Reuse previously computed values.
```
Before: a = b + c; d = b + c
After:  t = b + c; a = t; d = t
```

### 6.2 Loop Optimizations

**Loop Invariant Code Motion**: Move computations out of loops.
```
Before: for i in range(n): x = y * z; a[i] = x + i
After:  x = y * z; for i in range(n): a[i] = x + i
```

**Strength Reduction**: Replace expensive operations with cheaper ones.
```
Before: for i in range(n): a[i] = i * 4
After:  t = 0; for i in range(n): a[i] = t; t = t + 4
```

**Loop Unrolling**: Reduce loop overhead by expanding iterations.
```
Before: for i in range(4): sum += a[i]
After:  sum += a[0]; sum += a[1]; sum += a[2]; sum += a[3]
```

## 7. Code Generation

### 7.1 Instruction Selection

Mapping IR to target machine instructions using tree pattern matching:

```
IR tree:          Target instruction:
  +                MOV R1, [bp-4]
 / \               ADD R1, [bp-8]
x   y

  =                MOV [bp-4], R1
 / \
x   +
   / \
  y   z
```

### 7.2 Register Allocation

Graph coloring algorithm for register allocation:

1. Build interference graph (nodes = variables, edges = simultaneous live ranges)
2. Simplify: Remove nodes with degree < k (number of registers)
3. Spill: If no simplifiable node, select node to spill to memory
4. Select: Assign colors (registers) to nodes in reverse removal order

## 8. Conclusion

Modern compilers are complex software systems that transform high-level source code into efficient machine code through a series of well-defined phases. Understanding compiler design principles is essential for language designers, tool developers, and performance engineers seeking to understand the transformation from source to executable.

The field continues to evolve with new optimization techniques, just-in-time compilation strategies, and language features that challenge traditional compiler architectures. Future directions include machine learning-guided optimization, automatic vectorization, and compilation for heterogeneous computing platforms.

## References

1. Aho, A. V., Lam, M. S., Sethi, R., & Ullman, J. D. (2006). Compilers: Principles, Techniques, and Tools (2nd ed.).
2. Appel, A. W. (2004). Modern Compiler Implementation in Java (2nd ed.).
3. Cooper, K. D., & Torczon, L. (2011). Engineering a Compiler (2nd ed.).
4. Muchnick, S. S. (1997). Advanced Compiler Design and Implementation.
5. Cytron, R., et al. (1991). Efficiently computing static single assignment form and the control dependence graph.
