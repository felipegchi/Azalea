module Main where

import GHC.IO.Encoding

import Syntax.Lexer.Support
import Syntax.Parser

import System.Environment

import qualified Data.ByteString as SB
import Data.Text.Encoding (decodeUtf8)
import Data.Text (pack, unpack)

import Syntax.Tree ( drawTree )
import Error.Message ( ErrReport(ErrReport) )
import Error.PrettyPrint ( ppShow )
import Type.Checker ( exprTypeSynth, runGen ) 
import Type.Context ( applyContext, CtxElem(CtxAlpha) )

main :: IO ()
main = do
  setLocaleEncoding utf8
  [file] <- getArgs

  bs  <- SB.readFile file
  case runLexer parseExpr bs of
      Right res -> do
        putStrLn $ drawTree res
        print $ runGen $ do 
          (ty, ctx) <- exprTypeSynth [CtxAlpha "Int", CtxAlpha "String"] res
          pure (applyContext ctx ty)
      Left err -> putStrLn (unpack $ ppShow $ ErrReport (pack file) (decodeUtf8 bs) err)