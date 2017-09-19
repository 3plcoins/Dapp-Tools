module EVM.UnitTest where

import EVM
import EVM.ABI
import EVM.Debug
import EVM.Exec
import EVM.Keccak
import EVM.Solidity
import EVM.Types
import EVM.Machine (blob)
import EVM.Concrete (Concrete, Blob (B))

import Control.Lens
import Control.Monad.State.Strict hiding (state)

import Control.Monad.Par.Class (spawn_)
import Control.Monad.Par.IO (runParIO)

import Data.Binary.Get    (runGetOrFail)
import Data.ByteString    (ByteString)
import Data.List          (sort)
import Data.Map           (Map)
import Data.Text          (Text, unpack, isPrefixOf)
import Data.Text.Encoding (encodeUtf8)
import Data.Word          (Word32)
import System.IO          (hFlush, stdout)

import qualified Control.Monad.Par.Class as Par
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Map as Map

tick :: String -> IO ()
tick x = putStr x >> hFlush stdout

runUnitTestContract ::
  Mode -> Map Text SolcContract -> SourceCache -> (Text, [Text]) -> IO ()
runUnitTestContract _ contractMap _ (name, testNames) = do
  putStrLn $ "Running " ++ show (length testNames) ++ " tests for "
    ++ unpack name
  case preview (ix name) contractMap of
    Nothing ->
      error $ "Contract " ++ unpack name ++ " not found"
    Just theContract -> do
      let
        vm0 = initialUnitTestVm theContract (Map.elems contractMap)
        vm2 = case runState exec vm0 of
                (VMFailure e, _) ->
                  error ("Creation error: " ++ show e)
                (VMSuccess (B targetCode), vm1) -> do
                  execState (performCreation targetCode) vm1
        target = view (state . contract) vm2
        endowment = 0xffffffffffffffffffffffff
        vm3 = vm2 & env . contracts . ix target . balance +~ endowment

      case runState (setupCall target "setUp()" >> assign (state . gas) 6000000 >> exec) vm3 of
        (VMFailure _, _) -> do
          putStrLn "error in setUp()"
        (VMSuccess _, vm4) -> do
          let
            runOne testName = spawn_ $ do
              case runState (setupCall target testName >> assign (state . gas) 600000 >> exec) vm4 of
                (VMFailure _, _) ->
                  if "testFail" `isPrefixOf` testName
                    then return "."
                    else do
                      return "F"
                (VMSuccess _, vm5) -> do
                  case evalState (setupCall target "failed()" >> assign (state . gas) 10000 >> exec) vm5 of
                    VMSuccess (B out) ->
                      case runGetOrFail (getAbi AbiBoolType)
                             (LazyByteString.fromStrict out) of
                        Right (_, _, AbiBool False) ->
                          return "."
                        Right (_, _, AbiBool True) ->
                          if "testFail" `isPrefixOf` testName
                            then return "."
                            else do
                              return "F"
                        Right (_, _, _) ->
                          error "internal error"
                        Left (_, _, e) ->
                          error ("ds-test behaving strangely: " ++ e)
                    VMFailure e ->
                      error $ "ds-test behaving strangely (" ++ show e ++ ")"
          runParIO (mapM runOne testNames >>= mapM Par.get) >>= mapM_ tick
          tick "\n"

word32Bytes :: Word32 -> ByteString
word32Bytes x = BS.pack [byteAt x (3 - i) | i <- [0..3]]

setupCall :: Addr -> Text -> EVM Concrete ()
setupCall target abi = do
  resetState
  loadContract target
  assign (state . calldata) (blob (word32Bytes (abiKeccak (encodeUtf8 abi))))

initialUnitTestVm :: SolcContract -> [SolcContract] -> VM Concrete
initialUnitTestVm theContract _ =
  let
    vm = makeVm $ VMOpts
           { vmoptCode = view creationCode theContract
           , vmoptCalldata = ""
           , vmoptValue = 0
           , vmoptAddress = newContractAddress ethrunAddress 1
           , vmoptCaller = ethrunAddress
           , vmoptOrigin = ethrunAddress
           , vmoptGas = 60000000
           , vmoptCoinbase = 0
           , vmoptNumber = 0
           , vmoptTimestamp = 1
           , vmoptGaslimit = 0
           , vmoptDifficulty = 0
           }
    creator =
      initialContract mempty
        & set nonce 1
        & set balance 1000000000000000000000000000
  in vm
    & set (env . contracts . at ethrunAddress) (Just creator)
    -- & set (env . solcByCreationHash) (Map.fromList [(view creationCodehash c, c) | c <- theContracts])
    -- & set (env . solcByRuntimeHash) (Map.fromList [(view runtimeCodehash c, c) | c <- theContracts])

unitTestMarkerAbi :: Word32
unitTestMarkerAbi = abiKeccak (encodeUtf8 "IS_TEST()")

findUnitTests :: [SolcContract] -> [(Text, [Text])]
findUnitTests = concatMap f where
  f c =
    case c ^? abiMap . ix unitTestMarkerAbi of
      Nothing -> []
      Just _  ->
        let testNames = unitTestMethods c
        in if null testNames
           then []
           else [(view contractName c, testNames)]

unitTestMethods :: SolcContract -> [Text]
unitTestMethods c = sort (filter (isUnitTestName) (Map.elems (c ^. abiMap)))
  where
    isUnitTestName s =
      "test" `isPrefixOf` s
