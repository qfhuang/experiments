module Repl where

import Simpler
import Data.Attoparsec.Text
import qualified ParseForm as P
import qualified Data.Text as TS
import qualified Data.List as L
import System.Console.Haskeline

readPrompt prompt1 prompt2 = readPrompt' [] prompt1
  where readPrompt' acc pmt = runInputT defaultSettings (getInputLine pmt) >>=
          maybe (return Nothing) (cont acc)
        cont acc [] = return . Just . L.intercalate "\n" $ reverse acc
        cont acc line = readPrompt' (line : acc) prompt2

i_repl = do
  text <- readPrompt "> " ". " >>= maybe (error "EOF") return
  case P.parseForms $ TS.pack text of
    Fail text cxt msg -> error $ show (text, cxt, msg)
    Done _ forms -> putStrLn $ "parsed: " ++ show (map elemToTerm forms)
  i_repl

litSym = Literal . Sym
elemToTerm (P.Atom atom) = litSym . Global $ TS.unpack atom -- TODO: symbol maps
elemToTerm (P.Form []) = litSym nat_zero -- TODO: unit
-- TODO: process syntactic forms
elemToTerm (P.Form (first : rest)) = Apply first' rest'
  where first' = elemToTerm first
        rest' = map elemToTerm rest
