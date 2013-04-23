{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import Data.Maybe
import qualified Data.Text as T
import Safe (readMay)
import System.Directory
import System.Environment
import System.Exit
import System.Path

import Pygmalion.Analysis.Source
import Pygmalion.Config
import Pygmalion.Core
import Pygmalion.Log
import Pygmalion.RPC.Client
--import Pygmalion.JSON

main :: IO ()
main = do
  initLogger DEBUG -- Need to make this configurable.
  args <- getArgs
  wd <- getCurrentDirectory
  parseArgs wd args

usage :: IO ()
usage = do
  putStrLn $ "Usage: " ++ queryExecutable ++ " [command]"
  putStrLn   "where [command] is one of the following:"
  putStrLn   " --help                      Prints this message."
  putStrLn   " --compile-commands          Prints a clang compilation database."
  putStrLn   " --flags-for-file [file]     Prints the compilation flags for the"
  putStrLn   "                             given file, or nothing on failure. If"
  putStrLn   "                             the file isn't in the database, a guess"
  putStrLn   "                             will be printed if possible."
  putStrLn   " --directory-for-file [file] Prints the working directory at the time"
  putStrLn   "                             the file was compiled. Guesses if needed."
  putStrLn   " --definition-for [file] [line] [col]"
  putStrLn   " --callers [file] [line] [col]"
  putStrLn   " --callees [file] [line] [col]"
  putStrLn   " --identify [file] [line] [col]"
  putStrLn   " --display-ast [file]"
  bail

parseArgs :: FilePath -> [String] -> IO ()
parseArgs _  ["--generate-compile-commands"] = printCDB
parseArgs wd ["--compile-flags", f] = printFlags (asSourceFile wd f)
parseArgs wd ["--working-directory", f] = printDir (asSourceFile wd f)
parseArgs wd ["--definition", f, line, col] = printDef (asSourceFile wd f)
                                                       (readMay line) (readMay col)
parseArgs wd ["--callers", f, line, col] = printCallers (asSourceFile wd f)
                                                        (readMay line) (readMay col)
parseArgs wd ["--callees", f, line, col] = printCallees (asSourceFile wd f)
                                                        (readMay line) (readMay col)
parseArgs wd ["--display-ast", f] = printAST (asSourceFile wd f)
parseArgs _  ["--help"] = usage
parseArgs _  ["-h"]     = usage
parseArgs _ _           = usage

asSourceFile :: FilePath -> FilePath -> SourceFile
asSourceFile wd p = mkSourceFile $ maybe p id (absNormPath wd p)

-- FIXME: Reimplement with RPC.
printCDB :: IO ()
{-
printCDB = withDB $ \h -> getAllSourceFiles h >>= putStrLn . sourceRecordsToJSON
-}
printCDB = undefined

printFlags :: SourceFile -> IO ()
printFlags f = getConfiguration >>= getCommandInfoOr bail f >>= putFlags
  where putFlags (CommandInfo _ _ (Command _ args) _) = putStrLn . T.unpack . T.intercalate " " $ args

printDir :: SourceFile -> IO ()
printDir f = getConfiguration >>= getCommandInfoOr bail f >>= putDir
  where putDir (CommandInfo _ wd _ _) = putStrLn . T.unpack $ wd

getCommandInfoOr :: IO () -> SourceFile -> Config -> IO CommandInfo
getCommandInfoOr a f cf = do
  cmd <- rpcGetSimilarCommandInfo (ifPort cf) f
  unless (isJust cmd) a
  return . fromJust $ cmd

printDef :: SourceFile -> Maybe Int -> Maybe Int -> IO ()
printDef f (Just line) (Just col) = do
    cf <- getConfiguration
    cmd <- getCommandInfoOr (bailWith cmdErr) f cf
    info <- getLookupInfo cmd (SourceLocation f line col)
    case info of
      GotDef di  -> putDef di
      -- FIXME Clean this up
      GotDecl usr di -> do def <- rpcGetDefinition (ifPort cf) usr
                           if isJust def then putDef (fromJust def)
                                         else putDecl di
      GotUSR usr -> do def <- rpcGetDefinition (ifPort cf) usr
                       unless (isJust def) $ bailWith (defErr usr)
                       putDef (fromJust def)
      GotNothing -> bailWith idErr
  where 
    errPrefix = (unSourceFile f) ++ ":" ++ (show line) ++ ":" ++ (show col) ++ ": "
    cmdErr = errPrefix ++ "No compilation information for this file."
    idErr = errPrefix ++ "No identifier at this location."
    defErr usr = errPrefix ++ "No definition for this identifier. USR = [" ++ (T.unpack usr) ++ "]"
    putDef (DefInfo n _ (SourceLocation idF idLine idCol) k) =
      putStrLn $ (unSourceFile idF) ++ ":" ++ (show idLine) ++ ":" ++ (show idCol) ++
                 ": Definition: " ++ (T.unpack n) ++ " [" ++ (T.unpack k) ++ "]"
    putDecl (DefInfo n _ (SourceLocation idF idLine idCol) k) =
      putStrLn $ (unSourceFile idF) ++ ":" ++ (show idLine) ++ ":" ++ (show idCol) ++
                 ": Declaration: " ++ (T.unpack n) ++ " [" ++ (T.unpack k) ++ "]"
printDef _ _ _ = usage

printCallers :: SourceFile -> Maybe Int -> Maybe Int -> IO ()
printCallers f (Just line) (Just col) = do
    cf <- getConfiguration
    cmd <- getCommandInfoOr (bailWith cmdErr) f cf
    info <- getLookupInfo cmd (SourceLocation f line col)
    case info of
      GotDef di     -> printCallers' (diUSR di) cf
      GotDecl usr _ -> printCallers' usr cf
      GotUSR usr    -> printCallers' usr cf
      GotNothing    -> bailWith idErr
  where 
    errPrefix = (unSourceFile f) ++ ":" ++ (show line) ++ ":" ++ (show col) ++ ": "
    cmdErr = errPrefix ++ "No compilation information for this file."
    idErr = errPrefix ++ "No identifier at this location."
    defErr usr = errPrefix ++ "No callers for this identifier. USR = [" ++ (T.unpack usr) ++ "]"
    printCallers' usr cf = do
      callers <- rpcGetCallers (ifPort cf) usr
      case (null callers) of
        True  -> bailWith (defErr usr)
        False -> mapM_ putCaller callers
    putCaller (Invocation (DefInfo n _ _ _) (SourceLocation idF idLine idCol)) =
      putStrLn $ (unSourceFile idF) ++ ":" ++ (show idLine) ++ ":" ++ (show idCol) ++
                 ": Caller: " ++ (T.unpack n)
printCallers _ _ _ = usage

printCallees :: SourceFile -> Maybe Int -> Maybe Int -> IO ()
printCallees f (Just line) (Just col) = do
    cf <- getConfiguration
    cmd <- getCommandInfoOr (bailWith cmdErr) f cf
    info <- getLookupInfo cmd (SourceLocation f line col)
    case info of
      GotDef di     -> printCallees' (diUSR di) cf
      GotDecl usr _ -> printCallees' usr cf
      GotUSR usr    -> printCallees' usr cf
      GotNothing    -> bailWith idErr
  where 
    errPrefix = (unSourceFile f) ++ ":" ++ (show line) ++ ":" ++ (show col) ++ ": "
    cmdErr = errPrefix ++ "No compilation information for this file."
    idErr = errPrefix ++ "No identifier at this location."
    defErr usr = errPrefix ++ "No callees for this identifier. USR = [" ++ (T.unpack usr) ++ "]"
    printCallees' usr cf = do
      callees <- rpcGetCallees (ifPort cf) usr
      case (null callees) of
        True  -> bailWith (defErr usr)
        False -> mapM_ putCallee callees
    putCallee (DefInfo n _ (SourceLocation idF idLine idCol) k) =
      putStrLn $ (unSourceFile idF) ++ ":" ++ (show idLine) ++ ":" ++ (show idCol) ++
                 ": Callee: " ++ (T.unpack n) ++ " [" ++ (T.unpack k) ++ "]"
printCallees _ _ _ = usage

printAST :: SourceFile -> IO ()
printAST f = getConfiguration >>= getCommandInfoOr (bailWith err) f >>= displayAST
  where err = "No compilation information for this file."

bail :: IO ()
bail = exitWith (ExitFailure (-1))

bailWith :: String -> IO ()
bailWith s = putStrLn s >> bail
