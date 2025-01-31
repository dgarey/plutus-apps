{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Spec.Emulator(tests) where


import Control.Lens (element, (%~), (&), (.~))
import Control.Monad (void)
import Control.Monad.Freer qualified as Eff
import Control.Monad.Freer.Error qualified as E
import Control.Monad.Freer.Writer (Writer, runWriter, tell)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy.Char8 (pack)
import Data.Default (Default (def))
import Data.Foldable (fold)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Hedgehog (Property, forAll, property)
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Ledger (OnChainTx (Valid), PaymentPubKeyHash, ScriptContext, Tx (txMint, txOutputs), TxOut (txOutValue), Value,
               outputs, scriptTxIn, scriptTxOut, txOutRefs, unspentOutputs)
import Ledger.Ada qualified as Ada
import Ledger.CardanoWallet qualified as CW
import Ledger.Generators (Mockchain (Mockchain))
import Ledger.Generators qualified as Gen
import Ledger.Index qualified as Index
import Ledger.Params ()
import Ledger.Validation qualified as Validation
import Ledger.Value qualified as Value
import Plutus.Contract.Test hiding (not)
import Plutus.Script.Utils.V1.Typed.Scripts (mkUntypedValidator)
import Plutus.Trace (EmulatorTrace, PrintEffect (PrintLn))
import Plutus.Trace qualified as Trace
import Plutus.V1.Ledger.Scripts (ScriptError (EvaluationError), Validator, mkValidatorScript, unitDatum, unitRedeemer)
import PlutusTx qualified
import PlutusTx.Numeric qualified as P
import PlutusTx.Prelude qualified as PlutusTx
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.Hedgehog (testProperty)
import Wallet (WalletAPIError, payToPaymentPublicKeyHash_, submitTxn)
import Wallet.API qualified as W
import Wallet.Emulator.Chain qualified as Chain
import Wallet.Emulator.Types (selectCoin)
import Wallet.Graph qualified

tests :: TestTree
tests = testGroup "all tests" [
    testGroup "UTXO model" [
        testProperty "compute UTxO of trivial blockchain" utxo,
        testProperty "validate transaction" txnValid,
        testProperty "update UTXO set after each transaction" txnUpdateUtxo
        ],
    testGroup "traces" [
        testProperty "accept valid txn" validTrace,
        testProperty "accept valid txn 2" validTrace2,
        testProperty "reject invalid txn" invalidTrace,
        testProperty "notify wallet" notifyWallet,
        testProperty "log script validation failures" invalidScript,
        testProperty "payToPaymentPubkey" payToPaymentPubKeyScript,
        testProperty "payToPaymentPubkey-2" payToPaymentPubKeyScript2
        ],
    testGroup "trace output" [
        goldenVsString
          "captures a trace of a wait"
          "test/Spec/golden/traceOutput - wait1.txt"
          (pure $ captureTrace (void $ Trace.waitNSlots 1)),
        goldenVsString
          "captures a trace of pubKeytransactions"
          "test/Spec/golden/traceOutput - pubKeyTransactions.txt"
          (pure $ captureTrace pubKeyTransactions),
        goldenVsString
          "captures a trace of pubKeytransactions2"
          "test/Spec/golden/traceOutput - pubKeyTransactions2.txt"
          (pure $ captureTrace pubKeyTransactions2)
    ],
    testGroup "Etc." [
        testProperty "selectCoin" selectCoinProp,
        testProperty "txnFlows" txnFlowsTest
        ]
    ]

captureTrace
    :: EmulatorTrace ()
    -> BSL.ByteString
captureTrace trace
  = pack $ unlines output
  where
    output = capturePrintEffect $ Trace.runEmulatorTraceEff def def trace

capturePrintEffect
         :: Eff.Eff '[PrintEffect] r
         -> [String]
capturePrintEffect effs = snd $ Eff.run (runWriter (Eff.reinterpret f effs))
  where
    f :: PrintEffect r -> Eff.Eff '[Writer [String]] r
    f = \case
      PrintLn s -> tell [s]


wallet1, wallet2, wallet3 :: Wallet
wallet1 = knownWallet 1
wallet2 = knownWallet 2
wallet3 = knownWallet 3

pubKey1, pubKey2, pubKey3 :: PaymentPubKeyHash
pubKey1 = mockWalletPaymentPubKeyHash wallet1
pubKey2 = mockWalletPaymentPubKeyHash wallet2
pubKey3 = mockWalletPaymentPubKeyHash wallet3

utxo :: Property
utxo = property $ do
    Mockchain txPool utxo params <- forAll Gen.genMockchain
    let
        cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex utxo
        signTx txn = Validation.fromPlutusTxSigned params cUtxoIndex txn CW.knownPaymentKeys
    Hedgehog.assert (unspentOutputs [map (Valid . signTx) txPool] == utxo)

txnValid :: Property
txnValid = property $ do
    (m, txn) <- forAll genChainTxn
    Gen.assertValid txn m

selectCoinProp :: Property
selectCoinProp = property $ do
    inputs <- forAll $ zip [(1 :: Integer) ..] <$> Gen.list (Range.linear 1 100) Gen.genValueNonNegative
    target <- forAll Gen.genValueNonNegative
    let result = Eff.run $ E.runError @WalletAPIError (selectCoin inputs target)
    case result of
        Left _ ->
            Hedgehog.assert $ not $ foldMap snd inputs `Value.geq` target
        Right (ins, change) ->
            Hedgehog.assert $ foldMap snd ins == (target P.+ change)

txnUpdateUtxo :: Property
txnUpdateUtxo = property $ do
    (Mockchain m utxo params, txn) <- forAll genChainTxn
    let options = defaultCheckOptions & emulatorConfig . Trace.initialChainState .~ Right m
        cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex utxo
        signedTx = Validation.fromPlutusTxSigned params cUtxoIndex txn CW.knownPaymentKeys

        -- submit the same txn twice, so it should be accepted the first time
        -- and rejected the second time.
        trace = do
            Trace.liftWallet wallet1 (submitTxn signedTx)
            Trace.liftWallet wallet1 (submitTxn signedTx)
        pred = \case
            [ Chain.TxnValidate{}
                , Chain.SlotAdd _
                , Chain.TxnValidate _ _
                , Chain.TxnValidationFail _ _ _ (Index.CardanoLedgerValidationError msg) _
                , Chain.SlotAdd _
                ] -> "BadInputsUTxO" `Text.isInfixOf` msg
            _ -> False
    checkPredicateInner options (assertChainEvents pred) trace Hedgehog.annotate Hedgehog.assert (const $ pure ())

validTrace :: Property
validTrace = property $ do
    (Mockchain m utxo params, txn) <- forAll genChainTxn
    let options = defaultCheckOptions & emulatorConfig . Trace.initialChainState .~ Right m
        cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex utxo
        signedTx = Validation.fromPlutusTxSigned params cUtxoIndex txn CW.knownPaymentKeys
        trace = Trace.liftWallet wallet1 (submitTxn signedTx)
    checkPredicateInner options assertNoFailedTransactions trace Hedgehog.annotate Hedgehog.assert (const $ pure ())

validTrace2 :: Property
validTrace2 = property $ do
    (Mockchain m utxo params, txn) <- forAll genChainTxn
    let options = defaultCheckOptions & emulatorConfig . Trace.initialChainState .~ Right m
        cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex utxo
        signedTx = Validation.fromPlutusTxSigned params cUtxoIndex txn CW.knownPaymentKeys
        trace = do
            Trace.liftWallet wallet1 (submitTxn signedTx)
            Trace.liftWallet wallet1 (submitTxn signedTx)
        predicate = assertFailedTransaction (\_ _ -> True)
    checkPredicateInner options predicate trace Hedgehog.annotate Hedgehog.assert (const $ pure ())

invalidTrace :: Property
invalidTrace = property $ do
    (Mockchain m utxo params, txn) <- forAll genChainTxn
    let invalidTxn = txn { txMint = Ada.adaValueOf 1 }
        cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex utxo
        signedTx = Validation.fromPlutusTxSigned params cUtxoIndex invalidTxn CW.knownPaymentKeys
        options = defaultCheckOptions & emulatorConfig . Trace.initialChainState .~ Right m
        trace = Trace.liftWallet wallet1 (submitTxn signedTx)
        pred = \case
            [ Chain.TxnValidate{}
                , Chain.SlotAdd _
                , Chain.TxnValidationFail _ _ _ (Index.CardanoLedgerValidationError msg) _
                , Chain.SlotAdd _
                ] -> "ValueNotConservedUTxO" `Text.isInfixOf` msg
            _ -> False
    checkPredicateInner options (assertChainEvents pred) trace Hedgehog.annotate Hedgehog.assert (const $ pure ())

invalidScript :: Property
invalidScript = property $ do
    (Mockchain _ _ params, txn1) <- forAll genChainTxn

    -- modify one of the outputs to be a script output
    index <- forAll $ Gen.int (Range.linear 0 ((length $ txOutputs txn1) - 1))
    let scriptTxn = txn1 & outputs . element index %~ \o -> scriptTxOut (txOutValue o) failValidator unitDatum
    Hedgehog.annotateShow scriptTxn
    let outToSpend = txOutRefs scriptTxn !! index
    let totalVal = txOutValue (fst outToSpend)

    -- try and spend the script output
    let invalidTxnUtxo = [(snd outToSpend, fst outToSpend)]
    let invalidTxnIns = map ((\txIn -> scriptTxIn txIn failValidator unitRedeemer unitDatum) . fst) invalidTxnUtxo
    invalidTxn <- forAll $ Gen.genValidTransactionSpending (Set.fromList invalidTxnIns) totalVal
    Hedgehog.annotateShow invalidTxn

    let cUtxoIndex = either (error . show) id $ Validation.fromPlutusIndex params $ Index.UtxoIndex $ Map.fromList invalidTxnUtxo
        signedInvalidTxn = Validation.fromPlutusTxSigned' params cUtxoIndex invalidTxn CW.knownPaymentKeys

    Hedgehog.assert (signedInvalidTxn == (Left (Left (Index.Phase2, Index.ScriptFailure (EvaluationError ["I always fail everything"] "CekEvaluationFailure: An error has occurred:  User error:\nThe provided Plutus code called 'error'.")))))
    where
        failValidator :: Validator
        failValidator = mkValidatorScript $$(PlutusTx.compile [|| mkUntypedValidator validator ||])
        validator :: () -> () -> ScriptContext -> Bool
        validator _ _ _ = PlutusTx.traceError "I always fail everything"

txnFlowsTest :: Property
txnFlowsTest =
    checkPredicateGen Gen.generatorModel
        (assertBlockchain $ \chain ->
           let numTx = length $ fold chain
               flows = Wallet.Graph.txnFlows [] chain
            in
                length flows > numTx)
        pubKeyTransactions

notifyWallet :: Property
notifyWallet =
    checkPredicateGen Gen.generatorModel
    (walletFundsChange wallet1 mempty)
    (pure ())

payToPaymentPubKeyScript :: Property
payToPaymentPubKeyScript =
    let hasInitialBalance w = walletFundsChange w mempty
    in checkPredicateGen Gen.generatorModel
        (hasInitialBalance wallet1
            .&&. hasInitialBalance wallet2
            .&&. hasInitialBalance wallet3)
        pubKeyTransactions

payToPaymentPubKeyScript2 :: Property
payToPaymentPubKeyScript2 =
    let hasInitialBalance w = walletFundsChange w mempty
    in checkPredicateGen Gen.generatorModel
        (hasInitialBalance wallet1
            .&&. hasInitialBalance wallet2
            .&&. hasInitialBalance wallet3)
        pubKeyTransactions2

pubKeyTransactions :: EmulatorTrace ()
pubKeyTransactions = do
    let five = Ada.adaValueOf 5
    Trace.liftWallet wallet1 $ payToPaymentPublicKeyHash_ def W.always five pubKey2
    _ <- Trace.nextSlot
    Trace.liftWallet wallet2 $ payToPaymentPublicKeyHash_ def W.always five pubKey3
    _ <- Trace.nextSlot
    Trace.liftWallet wallet3 $ payToPaymentPublicKeyHash_ def W.always five pubKey1
    void Trace.nextSlot

pubKeyTransactions2 :: EmulatorTrace ()
pubKeyTransactions2 = do
    let payment1 = initialBalance P.- Ada.adaValueOf 10
        payment2 = initialBalance P.+ Ada.adaValueOf 10
    Trace.liftWallet wallet1 $ payToPaymentPublicKeyHash_ def W.always payment1 pubKey2
    _ <- Trace.nextSlot
    Trace.liftWallet wallet2 $ payToPaymentPublicKeyHash_ def W.always payment2 pubKey3
    _ <- Trace.nextSlot
    Trace.liftWallet wallet3 $ payToPaymentPublicKeyHash_ def W.always payment2 pubKey1
    _ <- Trace.nextSlot
    Trace.liftWallet wallet1 $ payToPaymentPublicKeyHash_ def W.always (Ada.adaValueOf 20) pubKey2
    void Trace.nextSlot

genChainTxn :: Hedgehog.MonadGen m => m (Mockchain, Tx)
genChainTxn = do
    m <- Gen.genMockchain
    txn <- Gen.genValidTransaction m
    pure (m, txn)

initialBalance :: Value
initialBalance = Ada.adaValueOf 100
