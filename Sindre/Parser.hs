-----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Author      :  Troels Henriksen <athas@sigkill.dk>
-- License     :  MIT-style (see LICENSE)
--
-- Stability   :  unstable
-- Portability :  portable
--
-- Parser for the Sindre programming language
--
-----------------------------------------------------------------------------

module Sindre.Parser( parseSindre
                    , parseInteger
                    )
    where

import Sindre.Sindre hiding (SourcePos, position)

import System.Console.GetOpt

import Text.Parsec hiding ((<|>), many, optional)
import Text.Parsec.Expr
import Text.Parsec.Token (LanguageDef, GenLanguageDef(..))
import qualified Text.Parsec.Token as P

import Control.Applicative
import Control.Monad.Identity
import Data.Char hiding (Control)
import Data.Function
import Data.List hiding (insert)
import Data.Maybe
import qualified Data.Map as M
import qualified Data.Set as S

data Directive = GUIDirective GUIRoot
               | ActionDirective (Pattern, Action)
               | GlobalDirective (Identifier, P Expr)
               | FuncDirective (Identifier, Function)
               | OptDirective (Identifier, (SindreOption, Maybe Value))
               | BeginDirective [P Stmt]

definedBy :: [Directive] -> S.Set Identifier
definedBy = foldr f S.empty
    where f (GlobalDirective (k, _)) = S.insert k
          f (OptDirective (k, _)) = S.insert k
          f _ = id

getGUI :: [Directive] -> Either String (Maybe GUIRoot)
getGUI ds  = case foldl f [] ds of
               [gui'] -> Right $ Just gui'
               []     -> Right Nothing
               _      -> Left "Multiple GUI definitions"
    where f l (GUIDirective x) = x:l
          f l _                      = l

getActions :: [P Directive] -> [P (Pattern, Action)]
getActions = foldl f []
    where f l (P p (ActionDirective x)) = P p x:l
          f l _                         = l

getGlobals :: [P Directive] -> [P (Identifier, P Expr)]
getGlobals = foldl f []
    where f m (P p (GlobalDirective x)) = P p x:m
          f m       _                   = m

getFunctions :: [P Directive] -> [P (Identifier, Function)]
getFunctions = foldl f []
    where f m (P p (FuncDirective x)) = P p x:m
          f m _                       = m

getOptions :: [P Directive] -> [P (Identifier, (SindreOption, Maybe Value))]
getOptions = foldl f []
    where f m (P p (OptDirective x)) = P p x:m
          f m _                      = m

getBegin :: [Directive] -> [P Stmt]
getBegin = foldl f []
    where f m (BeginDirective x) = m++x
          f m _                        = m

applyDirectives :: [P Directive] -> Program -> Either String Program
applyDirectives ds prog = do
  let prog' = prog {
                programActions = getActions ds ++ programActions prog
              , programGlobals = globals' ++ getGlobals ds
              , programFunctions =
                  merge (getFunctions ds) (programFunctions prog)
              , programOptions = options' ++ getOptions ds
              , programBegin = getBegin ds' ++ programBegin prog
              }
  maybe prog' (\gui' -> prog' { programGUI = gui' }) <$> getGUI ds'
    where options' = filter (not . hasNewDef . fst . unP) (programOptions prog)
          globals' = filter (not . hasNewDef . fst . unP) (programGlobals prog)
          hasNewDef k = S.member k $ definedBy ds'
          merge = unionBy ((==) `on` fst . unP)
          ds' = map unP ds

type ParserState = S.Set Identifier

type Parser = Parsec String ParserState

position :: Parser (String, Int, Int)
position = do pos <- getPosition
              pure (sourceName pos, sourceLine pos, sourceColumn pos)

node :: Parser a -> Parser (P a)
node p = pure P <*> position <*> p

parseSindre :: Program -> SourceName -> String -> Either ParseError Program
parseSindre prog = runParser (sindre prog) S.empty

parseInteger :: String -> Maybe Integer
parseInteger = either (const Nothing) Just .
               runParser (integer <* eof) S.empty ""

sindre :: Program -> Parser Program
sindre prog = do ds <- reverse <$> many directive <* eof
                 either fail return $ applyDirectives ds prog

directive :: Parser (P Directive)
directive = directive' <* skipMany semi
    where directive' = node $
                           ActionDirective <$> reaction
                       <|> GUIDirective <$> gui
                       <|> GlobalDirective <$> constdef
                       <|> FuncDirective <$> functiondef
                       <|> OptDirective <$> optiondef
                       <|> BeginDirective <$> begindef

gui :: Parser (Maybe Value, GUI)
gui = reserved "GUI" *> braces gui'
      <?> "GUI definition"
    where gui' = do
            name' <- optional name
            clss <- node className
            args' <- M.fromList <$> args <|> pure M.empty
            orient' <- optional orient
            children' <- children <|> pure []
            return (orient',
                    GUI { widgetName = name'
                       , widgetClass = clss
                       , widgetArgs = args'
                       , widgetChildren = children'
                       })
          name = varName <* reservedOp "="
          args = parens $ commaSep arg
          arg = pure (,) <*> varName <* reservedOp "=" <*> expression
          children = braces $ many (gui' <* skipMany semi)
          orient = reservedOp "@" *> literal

functiondef :: Parser (Identifier, Function)
functiondef = reserved "function" *> pure (,)
              <*> try varName <*> function
              <?> "function definition"
    where function = pure Function 
                     <*> parens (commaSep varName)
                     <*> braces statements

optiondef :: Parser (Identifier, (SindreOption, Maybe Value))
optiondef = reserved "option" *> do
              var <- varName
              pure ((,) var) <*> parens (option' var)
              <?> "option definition"
    where option' var = do
            s <- optional shortopt <* optional comma
            l <- optional longopt <* optional comma
            odesc <- optional optdesc <* optional comma
            adesc <- optional argdesc <* optional comma
            defval <- optional literal
            let (s', l') = (maybeToList s, maybeToList l)
            let noargfun = NoArg $ M.insert var "true"
            let argfun = ReqArg $ \arg -> M.insert var arg
            return (Option s' l'
                    (maybe noargfun argfun adesc)
                    (fromMaybe "" odesc)
                   , defval)
          shortopt = try $ lexeme $ char '-' *> alphaNum
          longopt = string "--" *> identifier
          optdesc = stringLiteral
          argdesc = stringLiteral

begindef :: Parser [P Stmt]
begindef = reserved "BEGIN" *> braces statements

reaction :: Parser (Pattern, Action)
reaction = pure (,) <*> try pattern <*> action <?> "action"

constdef :: Parser (Identifier, P Expr)
constdef = pure (,) <*> try varName <* reservedOp "=" <*> expression

pattern :: Parser Pattern
pattern = simplepat `chainl1` (reservedOp "||" *> pure OrPattern)
    where simplepat =
                pure KeyPattern <*>
                     (reservedOp "<" *> keypress <* reservedOp ">")
            <|> pure SourcedPattern
                    <*> source <* string "->"
                    <*> varName
                    <*> parens (commaSep varName)

source :: Parser Source
source =     pure NamedSource <*> varName <*> field
         <|> pure GenericSource
                 <*> (char '$' *> className) <*> parens varName <*> field
    where field = optional $ char '.' *> varName

action :: Parser Action
action = StmtAction <$> braces statements

key :: Parser Key
key = do s <- identifier
         case s of [c] -> return $ CharKey c
                   _   -> return $ CtrlKey s

modifier :: Parser KeyModifier
modifier =     string "C" *> return Control
           <|> string "M" *> return Meta
           <|> string "Shift" *> return Shift
           <|> string "S" *> return Super
           <|> string "H" *> return Hyper

keypress :: Parser KeyPress
keypress = pure (,) <*> (S.fromList <$> many (try modifier <* char '-')) <*> key

statements :: Parser [P Stmt]
statements = many (statement <* skipMany semi) <?> "statement"

statement :: Parser (P Stmt)
statement = node $     
                 printstmt
             <|> quitstmt
             <|> returnstmt
             <|> (reserved "next" *> pure Next)
             <|> ifstmt
             <|> whilestmt
             <|> focusstmt
             <|> Expr <$> expression
    where printstmt = reserved "print" *>
                      (Print <$> commaSep expression)
          quitstmt  = reserved "exit" *>
                      (Exit <$> optional expression)
          returnstmt = reserved "return" *>
                       (Return <$> optional expression)
          ifstmt = (reserved "if" *> pure If)
                   <*> parens expression 
                   <*> braces statements
                   <*> (    reserved "else" *>
                            ((:[]) <$> node ifstmt <|> braces statements)
                        <|> return [])
          whilestmt = (reserved "while" *> pure While)
                      <*> parens expression
                      <*> braces statements
          focusstmt = reserved "focus" *> (Focus <$> expression)

keywords :: [String]
keywords = ["if", "else", "while", "for", "do",
            "function", "return", "continue", "break",
            "exit", "print", "GUI", "option"]

sindrelang :: LanguageDef ParserState
sindrelang = LanguageDef {
             commentStart = "/*"
           , commentEnd = "*/"
           , commentLine = "//"
           , nestedComments = True
           , identStart = letter
           , identLetter = alphaNum <|> char '_'
           , opStart = oneOf "+-/*&|;,<>"
           , opLetter = oneOf "=+-|&"
           , reservedNames = keywords
           , reservedOpNames = [ "++", "--"
                               , "^", "**"
                               , "+", "-", "/", "*", "%"
                               , "&&", "||", ";", ","
                               , "<", ">", "<=", ">=", "!="
                               , "=", "*=", "/=", "+=", "-="]
           , caseSensitive = True
  }

operators :: OperatorTable String ParserState Identity (P Expr)
operators = [ [ prefix "++" $
                preop Plus (Literal $ IntegerV 1)
              , postfix "++" PostInc
              , prefix "--" $
                preop Plus (Literal $ IntegerV $ -1)
              , postfix "--" PostDec ]
            , [ binary "**" RaisedTo AssocRight,
                binary "^" RaisedTo AssocRight ]
            , [ prefix "-" $ \e -> Times (Literal (IntegerV $ -1) `at` e) e
              , prefix "+" $ \(P _ e) -> e
              , prefix "!" Not ]
            , [ binary "*" Times AssocLeft,
                binary "/" Divided AssocLeft, binary "%" Modulo AssocLeft ]
            , [ binary "+" Plus AssocLeft, binary "-" Minus AssocLeft ]
            , [ binary "==" Equal AssocNone 
              , binary "<" LessThan AssocNone 
              , binary ">" (flip LessThan) AssocNone 
              , binary "<=" LessEql AssocNone
              , binary ">=" (flip LessEql) AssocNone
              , binary "!=" (\e1@(P p _) e2 -> Not $ P p $ Equal e1 e2) AssocNone ]
            , [ binary "&&" And AssocRight ]
            , [ binary "||" Or AssocRight ]
            , [ binary "=" Assign AssocRight
              , binary "*=" (inplace Times) AssocLeft
              , binary "/=" (inplace Divided) AssocLeft
              , binary "+=" (inplace Plus) AssocLeft
              , binary "-=" (inplace Minus) AssocLeft]
            ]
    where binary  name fun       = Infix $ do
                                     p <- position
                                     reservedOp name
                                     pure (\e1 e2 -> P p $ fun e1 e2)
          prefix  name fun       = Prefix $ do
                                     p <- position
                                     reservedOp name
                                     pure $ P p . fun
          postfix name fun       = Postfix $ do
                                     p <- position
                                     reservedOp name
                                     pure $ P p . fun
          inplace op e1@(P pos _) e2 = e1 `Assign` P pos (e1 `op` e2)
          preop op e1 e2@(P pos _) = e2 `Assign` P pos (e2 `op` P pos e1)

expression :: Parser (P Expr)
expression = buildExpressionParser operators term <?> "expression"
    where term = try atomic <|> compound

atomic :: Parser (P Expr)
atomic =     parens expression
         <|> node (Literal <$> literal)
         <|> dictlookup

literal :: Parser Value
literal =     pure IntegerV <*> integer
          <|> pure StringV <*> stringLiteral
          <?> "literal value"

compound :: Parser (P Expr)
compound =
  field' `chainl1` (char '.' *> pure comb)
    where comb e (P _ (Var v)) = FieldOf v e `at` e
          comb e (P _ (Funcall v es)) = Methcall e v es `at` e
          comb _ _ = undefined -- Will never happen
          field' = try fcall <|> node (Var <$> varName)

lexer :: P.TokenParser ParserState
lexer = P.makeTokenParser sindrelang
lexeme :: Parser a -> Parser a
lexeme = P.lexeme lexer
comma :: Parser String
comma = P.comma lexer
commaSep :: Parser a -> Parser [a]
commaSep = P.commaSep lexer
semi :: Parser String
semi = P.semi lexer
parens :: Parser a -> Parser a
parens = P.parens lexer
braces :: Parser a -> Parser a
braces = P.braces lexer
brackets :: Parser a -> Parser a
brackets = P.brackets lexer
fcall :: Parser (P Expr)
fcall = node $ pure Funcall <*> varName <*>
        parens (sepBy expression comma)
dictlookup :: Parser (P Expr)
dictlookup = node $ pure Lookup <*> varName <*>
             brackets expression
className :: Parser String
className = lookAhead (satisfy isUpper) *> identifier <?> "class"
varName :: Parser String
varName = lookAhead (satisfy isLower) *> identifier <?> "variable"
identifier :: Parser String
identifier = P.identifier lexer
integer :: Parser Integer
integer = P.integer lexer
stringLiteral :: Parser String
stringLiteral = P.stringLiteral lexer
reservedOp :: String -> Parser ()
reservedOp = P.reservedOp lexer
reserved :: String -> Parser ()
reserved = P.reserved lexer
