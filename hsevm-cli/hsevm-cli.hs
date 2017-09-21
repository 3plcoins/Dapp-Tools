-- Main file of the hsevm CLI program

{-# Language BangPatterns #-}
{-# Language CPP #-}
{-# Language DeriveGeneric #-}
{-# Language GeneralizedNewtypeDeriving #-}
{-# Language LambdaCase #-}
{-# Language NumDecimals #-}
{-# Language OverloadedStrings #-}
{-# Language TemplateHaskell #-}

import qualified EVM as EVM
import qualified EVM.Concrete as EVM
import qualified EVM.TTY as EVM.TTY
import qualified EVM.FeeSchedule as FeeSchedule
import EVM.Machine (w256)

#if MIN_VERSION_aeson(1, 0, 0)
import qualified EVM.VMTest as VMTest
#endif

import EVM.Debug
import EVM.Exec
import EVM.Solidity
import EVM.Types hiding (word)
import EVM.UnitTest (UnitTestOptions, findUnitTests, runUnitTestContract)

import qualified EVM.UnitTest as EVM.UnitTest

import qualified Paths_hsevm as Paths

import Control.Concurrent.Async   (async, waitCatch)
import Control.Exception          (evaluate)
import Control.Lens
import Control.Monad              (void)
import Control.Monad.State.Strict (execState)
import Data.ByteString            (ByteString)
import Data.List                  (intercalate, isSuffixOf)
import Data.Maybe                 (fromMaybe)
import System.Directory           (withCurrentDirectory, listDirectory)
import System.Exit                (die)
import System.IO                  (hFlush, stdout)
import System.Process             (callProcess)
import System.Timeout             (timeout)

import qualified Data.ByteString        as ByteString
import qualified Data.ByteString.Base16 as BS16
import qualified Data.ByteString.Lazy   as LazyByteString
import qualified Data.Map               as Map
import qualified Options.Generic        as Options

import qualified EVM.Facts     as Facts
import qualified EVM.Facts.Git as Git

-- This record defines the program's command-line options
-- automatically via the `optparse-generic` package.
data Command
  = Exec
      { code       :: ByteString
      , calldata   :: Maybe ByteString
      , address    :: Maybe Addr
      , caller     :: Maybe Addr
      , origin     :: Maybe Addr
      , coinbase   :: Maybe Addr
      , value      :: Maybe W256
      , gas        :: Maybe W256
      , number     :: Maybe W256
      , timestamp  :: Maybe W256
      , gaslimit   :: Maybe W256
      , difficulty :: Maybe W256
      , debug      :: Bool
      , state      :: Maybe String
      }
  | DappTest
      { jsonFile           :: Maybe String
      , dappRoot           :: Maybe String
      , debug              :: Bool
      , gasForCreating     :: Maybe W256
      , gasForInvoking     :: Maybe W256
      , balanceForCreator  :: Maybe W256
      , balanceForCreated  :: Maybe W256
      }
  | Interactive
      { jsonFile           :: Maybe String
      , dappRoot           :: Maybe String
      , gasForCreating     :: Maybe W256
      , gasForInvoking     :: Maybe W256
      , balanceForCreator  :: Maybe W256
      , balanceForCreated  :: Maybe W256
      }
  | VmTest
      { file  :: String
      , test  :: [String]
      , debug :: Bool
      }
  | VmTestReport
      { tests :: String
      }
  deriving (Show, Options.Generic, Eq)

instance Options.ParseRecord Command where
  parseRecord =
    Options.parseRecordWithModifiers Options.lispCaseModifiers

defaultGasForCreating :: W256
defaultGasForCreating = 6000000

defaultGasForInvoking :: W256
defaultGasForInvoking = 6000000

defaultBalanceForCreator :: W256
defaultBalanceForCreator = 0

defaultBalanceForCreated :: W256
defaultBalanceForCreated = 0

optsMode :: Command -> Mode
optsMode x = if debug x then Debug else Run

unitTestOptions :: Command -> UnitTestOptions
unitTestOptions cmd =
  EVM.UnitTest.UnitTestOptions
    { EVM.UnitTest.gasForCreating =
        fromMaybe defaultGasForCreating (gasForCreating cmd)
    , EVM.UnitTest.gasForInvoking =
        fromMaybe defaultGasForInvoking (gasForInvoking cmd)
    , EVM.UnitTest.balanceForCreator =
        fromMaybe defaultBalanceForCreator (balanceForCreator cmd)
    , EVM.UnitTest.balanceForCreated =
        fromMaybe defaultBalanceForCreated (balanceForCreated cmd)
    }

main :: IO ()
main = do
  cmd <- Options.getRecord "hsevm -- Ethereum evaluator"
  let
    root = fromMaybe "." (dappRoot cmd)
    testOpts = unitTestOptions cmd
  case cmd of
    Exec {} ->
      launchExec cmd
    VmTest {} ->
      launchVMTest cmd
    DappTest {} ->
      withCurrentDirectory root $ do
        testFile <- findTestFile (jsonFile cmd)
        dappTest testOpts (optsMode cmd) testFile
    Interactive {} ->
      withCurrentDirectory root $ do
        testFile <- findTestFile (jsonFile cmd)
        EVM.TTY.main testOpts root testFile
    VmTestReport {} ->
      withCurrentDirectory (tests cmd) $ do
        dataDir <- Paths.getDataDir
        callProcess "bash" [dataDir ++ "/run-consensus-tests", "."]

findTestFile :: Maybe String -> IO String
findTestFile (Just s) = pure s
findTestFile Nothing = do
  outFiles <- listDirectory "out"
  case filter (isSuffixOf ".t.sol.json") outFiles of
    [x] -> pure ("out/" ++ x)
    [] ->
      error $ concat
        [ "No `*.t.sol.json' file found in `./out'.\n"
        , "Maybe you need to run `dapp build'.\n"
        , "You can specify a file with `--json-file'."
        ]
    xs ->
      error $ concat
        [ "Multiple `*.t.sol.json' files found in `./out'.\n"
        , "Specify one using `--json-file'.\n"
        , "Files found: "
        , intercalate ", " xs
        ]

dappTest :: UnitTestOptions -> Mode -> String -> IO ()
dappTest opts _ solcFile = do
  readSolc solcFile >>=
    \case
      Just (contractMap, cache) -> do
        let unitTests = findUnitTests (Map.elems contractMap)
        mapM_ (runUnitTestContract opts contractMap cache) unitTests
      Nothing ->
        error ("Failed to read Solidity JSON for `" ++ solcFile ++ "'")

launchExec :: Command -> IO ()
launchExec cmd = do
  let vm = vmFromCommand cmd
  vm1 <- case state cmd of
    Nothing -> pure vm
    Just path ->
      -- Note: this will load the code, so if you've specified a state
      -- repository, then you effectively can't change `--code' after
      -- the first run.
      Facts.apply vm <$> Git.loadFacts (Git.RepoAt path)

  case optsMode cmd of
    Run ->
      let vm' = execState exec vm1
      in case view EVM.result vm' of
        Nothing ->
          error "internal error; no EVM result"
        Just (EVM.VMFailure e) -> do
          die (show e)
        Just (EVM.VMSuccess (EVM.B x)) -> do
          let hex = BS16.encode x
          if ByteString.null hex then pure ()
            else do
              ByteString.putStr hex
              putStrLn ""
          case state cmd of
            Nothing -> pure ()
            Just path ->
              Git.saveFacts (Git.RepoAt path) (Facts.vmFacts vm')
    Debug ->
      void (EVM.TTY.runFromVM vm)

vmFromCommand :: Command -> EVM.VM EVM.Concrete
vmFromCommand cmd =
  vm1 & EVM.env . EVM.contracts . ix address' . EVM.balance +~ (w256 value')
  where
    value'   = word value 0
    address' = addr address 1
    vm1 = EVM.makeVm $ EVM.VMOpts
      { EVM.vmoptCode       = hexByteString "--code" (code cmd)
      , EVM.vmoptCalldata   = maybe "" (hexByteString "--calldata")
                                (calldata cmd)
      , EVM.vmoptValue      = value'
      , EVM.vmoptAddress    = address'
      , EVM.vmoptCaller     = addr caller 2
      , EVM.vmoptOrigin     = addr origin 3
      , EVM.vmoptGas        = word gas 0
      , EVM.vmoptCoinbase   = addr coinbase 0
      , EVM.vmoptNumber     = word number 0
      , EVM.vmoptTimestamp  = word timestamp 0
      , EVM.vmoptGaslimit   = word gaslimit 0
      , EVM.vmoptDifficulty = word difficulty 0
      , EVM.vmoptSchedule   = FeeSchedule.metropolis
      }
    word f def = maybe def id (f cmd)
    addr f def = maybe def id (f cmd)

launchVMTest :: Command -> IO ()
launchVMTest cmd =
#if MIN_VERSION_aeson(1, 0, 0)
  VMTest.parseSuite <$> LazyByteString.readFile (file cmd) >>=
   \case
     Left err -> print err
     Right allTests ->
       let testFilter =
             if null (test cmd)
             then id
             else filter (\(x, _) -> elem x (test cmd))
       in
         mapM_ (runVMTest (optsMode cmd)) $
           testFilter (Map.toList allTests)
#else
  putStrLn "Not supported"
#endif

#if MIN_VERSION_aeson(1, 0, 0)
runVMTest :: Mode -> (String, VMTest.Case) -> IO Bool
runVMTest mode (name, x) = do
  let vm = VMTest.vmForCase x
  putStr (name ++ " ")
  hFlush stdout
  result <- do
    action <- async $
      case mode of
        Run -> do
          timeout (1e6) . evaluate $ execState exec vm
        Debug ->
          Just <$> EVM.TTY.runFromVM vm
    waitCatch action
  case result of
    Right (Just vm') -> do
      ok <- VMTest.checkExpectation x vm'
      putStrLn (if ok then "ok" else "")
      return ok
    Right Nothing -> do
      putStrLn "timeout"
      return False
    Left _ -> do
      putStrLn "error"
      return False

#endif
