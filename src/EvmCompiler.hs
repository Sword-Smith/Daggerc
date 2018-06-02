module EvmCompiler where

import EvmCompilerHelper
import EvmLanguageDefinition
import IntermediateLanguageDefinition

import Control.Monad.State.Lazy
import qualified Data.Map.Strict as Map
import Data.Word

-- State monad definitions
data CompileEnv = CompileEnv { labelCount :: Integer,
                               transferCallCount :: Integer,
                               memOffset :: Integer,
                               labelString :: [Char]
                               } deriving Show

type CompileGet a = State CompileEnv a

-- Return a new, unique label. Argument can be anything but should be
-- descriptive since this will ease debugging.
newLabel :: String -> CompileGet String
newLabel desc = do
  compileEnv <- get
  let i = labelCount compileEnv
  let j = transferCallCount compileEnv
  let k = labelString compileEnv
  put compileEnv { labelCount = i + 1 }
  return $ desc ++ "_" ++ (show i) ++ "_" ++ (show j) ++ "_" ++ (show k)

-- ATM, "Executed" does not have an integer. If it should be able to handle more
-- than 256 tcalls, it must take an integer also.
data StorageType = CreationTimestamp
                 | Executed
                 | Activated
                 | MemoryExpressionRefs

-- For each storage index we pay 20000 GAS. Reusing one is only 5000 GAS.
-- It would therefore make sense to pack as much as possible into the same index.
 -- Storage is word addressed, not byte addressed
getStorageAddress :: StorageType -> Word32
getStorageAddress CreationTimestamp      = 0x0
getStorageAddress Activated              = 0x1
getStorageAddress Executed               = 0x2
getStorageAddress MemoryExpressionRefs   = 0x3

asmToMachineCode :: [EvmOpcode] -> String
asmToMachineCode opcodes = foldl (++) "" (map ppEvm opcodes)

getSizeOfOpcodeList :: [EvmOpcode] -> Integer
getSizeOfOpcodeList xs = foldl (+) 0 (map getOpcodeSize xs)

-- This function is called before the linker and before the
-- elimination of pseudo instructions, so it must be able to
-- also handle the pseudo instructions before and after linking
getOpcodeSize :: EvmOpcode -> Integer
getOpcodeSize (PUSH1  _)      = 2
getOpcodeSize (PUSH4 _)       = 5
getOpcodeSize (PUSH32 _)      = 33
getOpcodeSize (JUMPITO _)     = 1 + 5 -- PUSH4 addr.; JUMPI
getOpcodeSize (JUMPTO _)      = 1 + 5 -- PUSH4 addr.; JUMP
getOpcodeSize (JUMPITOA _)    = 1 + 5 -- PUSH4 addr.; JUMP
getOpcodeSize (JUMPTOA _)     = 1 + 5 -- PUSH4 addr.; JUMP
getOpcodeSize (FUNSTART _ _n) = 1 + 1 -- JUMPDEST; SWAPn
-- PC stores in µ[0] PC before PC opcode, we want to store the address
-- pointing to the OPCODE after the JUMP opcode. Therefore, we add 10 to byte code address
getOpcodeSize (FUNCALL _)     = 4 + 7 -- PC; PUSH1 10, ADD, JUMPTO label; JUMPDEST = PC; PUSH1, ADD, PUSH4 addr; JUMP; JUMPDEST; OPCODE -- addr(OPCODE)=µ[0]
getOpcodeSize FUNRETURN       = 2 -- SWAP1; JUMP;
getOpcodeSize _               = 1

-- Called as part of linker so must be able to handle pre-linker instructions.
replaceLabel :: Label -> Integer -> [EvmOpcode] -> [EvmOpcode]
replaceLabel label int insts =
  let
    replaceLabelH label i inst = case inst of
      (JUMPTO  l)      -> if l == label then JUMPTOA  i else JUMPTO  l
      (JUMPITO l)      -> if l == label then JUMPITOA i else JUMPITO l
      (JUMPDESTFROM l) -> if l == label then JUMPDEST else JUMPDESTFROM l
      (FUNSTART l n)   -> if l == label then FUNSTARTA n else FUNSTART l n
      (FUNCALL l)      -> if l == label then FUNCALLA i else FUNCALL l
      otherInst -> otherInst
  in
    map (replaceLabelH label int) insts

linker :: [EvmOpcode] -> [EvmOpcode]
linker insts =
  let
    linkerH :: Integer -> [EvmOpcode] -> [EvmOpcode] -> [EvmOpcode]
    linkerH inst_count insts_replaced (inst:insts) = case inst of
      JUMPDESTFROM label -> linkerH (inst_count + 1) (replaceLabel label inst_count insts_replaced) insts
      FUNSTART label _   -> linkerH (inst_count + 2) (replaceLabel label inst_count insts_replaced) insts
      _                  -> linkerH (inst_count + getOpcodeSize(inst)) insts_replaced insts
    linkerH _ insts_replaced [] = insts_replaced
  in
    linkerH 0 insts insts

-- Called after linker so should not handle pre-linker instructions
eliminatePseudoInstructions :: [EvmOpcode] -> [EvmOpcode]
eliminatePseudoInstructions (inst:insts) = case inst of
  (JUMPTOA i)  -> (PUSH4 (fromInteger i)):JUMP:eliminatePseudoInstructions(insts)
  (JUMPITOA i) -> (PUSH4 (fromInteger i)):JUMPI:eliminatePseudoInstructions(insts)
  (FUNCALLA i) -> PC : PUSH1 (fromInteger 10) : ADD : (PUSH4 (fromInteger i)) : JUMP : JUMPDEST : eliminatePseudoInstructions(insts)
  (FUNSTARTA n) -> JUMPDEST:(getSwap n):eliminatePseudoInstructions(insts)
  FUNRETURN    -> SWAP1:JUMP:eliminatePseudoInstructions(insts)
  inst         -> inst:eliminatePseudoInstructions(insts)
  where
      getSwap :: Integer -> EvmOpcode
      getSwap n =
        case n of
          2 -> SWAP2
          3 -> SWAP3
          _ -> undefined -- Only 2 or 3 args is accepted atm

eliminatePseudoInstructions [] = []

getFunctionSignature :: String -> Word32
getFunctionSignature funDecl = read $ "0x" ++ take 8 (keccak256 funDecl)

-- Main method for this module. Returns binary.
-- Check that there are not more than 2^8 transfercalls
-- or more than 2^7 mem exps (each mem exp is one dibit)
-- Wrapper for intermediateToOpcodesH
intermediateToOpcodes :: IntermediateContract -> String
intermediateToOpcodes (IntermediateContract tcs iMemExps activateMap marginRefundMap) =
  let
     -- linker is called as part of evmCompile
    intermediateToOpcodesH :: IntermediateContract -> String
    intermediateToOpcodesH = asmToMachineCode . eliminatePseudoInstructions . evmCompile
  in
    if length(tcs) > 256 || length(iMemExps) > 128
    then undefined
    else intermediateToOpcodesH (IntermediateContract tcs iMemExps activateMap marginRefundMap)

-- Given an IntermediateContract, returns the EvmOpcodes representing the contract
evmCompile :: IntermediateContract -> [EvmOpcode]
evmCompile (IntermediateContract tcs iMemExps activateMap marginRefundMap) =
  let
    constructor      = getConstructor tcs
    body             = jumpTable ++ subroutines ++ checkIfActivated ++ execute ++ activate
    codecopy         = getCodeCopy constructor body
    jumpTable        = getJumpTable
    subroutines      = getSubroutines -- TODO: If we want to do dynamic inclusion of obs getter, then specify here.
    checkIfActivated = getActivateCheck
    execute          = getExecute iMemExps tcs marginRefundMap -- also contains selfdestruct when contract is fully executed
    activate         = getActivate activateMap
  in
    -- The addresses of the constructor run are different from runs when DC is on BC
    linker (constructor ++ codecopy) ++ linker body

-- Once the values have been placed in storage, the CODECOPY opcode should
-- probably be called.
getConstructor :: [TransferCall] -> [EvmOpcode]
getConstructor tcs =
  (getCheckNoValue "Constructor_Header" ) ++
  setExecutedWord tcs

-- Checks that no value (ether) is sent when executing contract method
-- Used in both contract header and in constructor
getCheckNoValue :: String -> [EvmOpcode]
getCheckNoValue target = [CALLVALUE,
                          ISZERO,
                          JUMPITO target,
                          THROW,
                          JUMPDESTFROM target]

-- Stores timestamp of creation of contract in storage
saveTimestampToStorage :: [EvmOpcode]
saveTimestampToStorage =  [TIMESTAMP,
                           PUSH4 $ getStorageAddress CreationTimestamp,
                           SSTORE]

-- Given a number of transfercalls, set executed word in storage
-- A setMemExpWord is not needed since that word is initialized to zero automatically
setExecutedWord :: [TransferCall] -> [EvmOpcode]
setExecutedWord []  = undefined
setExecutedWord tcs = [ PUSH32 $ integer2w256 $ 2^length(tcs) - 1,
                        PUSH4 $ getStorageAddress Executed,
                        SSTORE ]

-- Returns the code needed to transfer code from *init* to I_b in the EVM
getCodeCopy :: [EvmOpcode] -> [EvmOpcode] -> [EvmOpcode]
getCodeCopy con exe = [PUSH4 $ fromInteger (getSizeOfOpcodeList exe),
                       PUSH4 $ fromInteger (getSizeOfOpcodeList con + 22),
                       PUSH1 0,
                       CODECOPY,
                       PUSH4 $ fromInteger (getSizeOfOpcodeList exe),
                       PUSH1 0,
                       RETURN,
                       STOP] -- 22 is the length of itself, right now we are just saving in mem0

getJumpTable :: [EvmOpcode]
getJumpTable =
  let
    -- This does not allow for multiple calls.
    switchStatement = [PUSH1 0,
                       CALLDATALOAD,
                       PUSH32 (0xffffffff, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0),
                       AND,
                       DUP1,
                       PUSH32 $ (getFunctionSignature "execute()" , 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0),
                       EVM_EQ,
                       JUMPITO "execute_method",
                       PUSH32 $ (getFunctionSignature "activate()", 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0),
                       EVM_EQ,
                       JUMPITO "activate_method",
                       JUMPDESTFROM "global_throw",
                       THROW]
  in
    (getCheckNoValue "Contract_Header") ++ switchStatement

getSubroutines :: [EvmOpcode]
getSubroutines = getTransferSubroutine ++ getTransferFromSubroutine
  where

    getTransferFromSubroutine =
      funStartTF
      ++ storeFunctionSignature TransferFrom
      ++ storeArgumentsTF -- transferFrom(_from, _to, _amount) = transferFrom(party, self, amount)
      ++ pushOutSize
      ++ pushOutOffset
      ++ pushInSizeTF
      ++ pushInOffset
      ++ pushValue
      ++ pushCalleeAddress
      ++ pushGasAmount
      ++ callInstruction
      ++ checkExitCode
      ++ removeExtraArg
      ++ getReturnValueFromMemory
      ++ funEnd

    getTransferSubroutine =
      funStartT
      ++ storeFunctionSignature Transfer
      ++ storeArgumentsT -- transfer(_to, _amount) = transfer(party, amount)
      ++ pushOutSize
      ++ pushOutOffset
      ++ pushInSizeT
      ++ pushInOffset
      ++ pushValue
      ++ pushCalleeAddress
      ++ pushGasAmount
      ++ callInstruction
      ++ checkExitCode
      ++ removeExtraArg
      ++ getReturnValueFromMemory
      ++ funEnd

    funStartT               = [ FUNSTART "transfer_subroutine" 3 ]
    funStartTF              = [ FUNSTART "transferFrom_subroutine" 3 ]
    storeFunctionSignature :: FunctionSignature -> [EvmOpcode]
    storeFunctionSignature Transfer  =
      [ PUSH32 (getFunctionSignature "transfer(address,uint256)", 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0)
      , PUSH1 0 -- TODO: We always use 0 here, since we don't use memory other places. Use monad to keep track of memory usage.
      , MSTORE ]
    storeFunctionSignature TransferFrom  =
      [ PUSH32 (getFunctionSignature "transferFrom(address,address,uint256)", 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0)
      , PUSH1 0
      , MSTORE ]
    storeArgumentsT =
      [ PUSH1 0x04
      , MSTORE -- store recipient (_to) in mem
      , PUSH1 0x24
      , MSTORE -- store amount in mem
      ]
    storeArgumentsTF =
      [ PUSH1 0x04
      , MSTORE -- store sender (_from) in mem
      , ADDRESS
      , PUSH1 0x24
      , MSTORE -- store own address (_to) in mem (recipient of transferFrom transaction)
      , PUSH1 0x44
      , MSTORE -- store amount in mem
      ]
    pushOutSize        = [ PUSH1 0x20 ]
    pushOutOffset      = [ PUSH1 0x0 ]
    pushInSizeTF       = [ PUSH1 0x64 ]
    pushInSizeT        = [ PUSH1 0x44 ]
    pushInOffset       = [ PUSH1 0x0 ]
    pushValue          = [ PUSH1 0x0 ]
    pushCalleeAddress  = [ DUP6 ]
    pushGasAmount      =
      [ PUSH1 0x32
      , GAS
      , SUB ]
    callInstruction    = [ CALL ]
    checkExitCode      =
      [ ISZERO
      , JUMPITO "global_throw" ]
    removeExtraArg           = [ POP ]
    getReturnValueFromMemory =
      [ PUSH1 0x0
      , MLOAD ]
    funEnd = [FUNRETURN]

-- When calling execute(), PC must be set here
-- to check if the DC is activated
-- throw iff activated bit is zero
getActivateCheck :: [EvmOpcode]
getActivateCheck =
  [ JUMPDESTFROM "execute_method"
  , PUSH4 $ getStorageAddress Activated
  , SLOAD
  , PUSH1 $ fromInteger 1
  , AND
  , ISZERO
  , JUMPITO "global_throw" ]

getExecute :: [IMemExp] -> [TransferCall] -> MarginRefundMap -> [EvmOpcode]
getExecute mes tcs mrm =
  concatMap getExecuteIMemExp mes ++ evalState (liftM concat (mapM getExecuteMarginRefundM ( Map.assocs mrm ))) 0 ++ getExecuteTCs mes tcs

-- This sets the relevant bits in the memory expression word in storage
-- Here the IMemExp should be evaluated. But only iff it is NOT true atm.
-- And also only iff current time is less than time in the IMemExp

-- The new plan is to use two bits to set the value of the memExp:
-- one if the memExp is evaluated to true, and one for false:
-- The empty value 00 would then indicate that the value of this
-- memExp has not yet been determined. The value 11 would be an invalid
-- value, 01 would be false, and 10 true.
getExecuteIMemExp :: IMemExp -> [EvmOpcode]
getExecuteIMemExp (IMemExp beginTime endTime count iExp) =
  let
    checkIfExpShouldBeEvaluated =
      let
        -- It should be considered which of the next three codeblocks
        -- it is cheaper to put first. Both read from storage so it might
        -- be irrelevant.

        checkIfMemExpIsTrueOrFalse  =
          [ PUSH4 $ getStorageAddress MemoryExpressionRefs
          , SLOAD
          , PUSH32 $ integer2w256 $ 0x3 * 2 ^ (2 * count) -- bitmask
          , AND
          , JUMPITO $ "memExp_end" ++ show count ]

        -- TODO: The same value is read from storage twice. Use DUP instead?
        checkIfTimeHasStarted =
          [ PUSH4 $ getStorageAddress CreationTimestamp
          , SLOAD
          , TIMESTAMP
          , SUB
          , PUSH32 $ integer2w256 beginTime
          , EVM_GT
          , JUMPITO $ "memExp_end" ++ show count ]

        -- If the memory expression is neither true nor false
        -- and the time has run out, its value is set to false.
        checkIfTimeHasPassed =
          [ PUSH4 $ getStorageAddress CreationTimestamp
          , SLOAD
          , TIMESTAMP
          , SUB
          , PUSH32 $ integer2w256 endTime
          , EVM_GT
          , JUMPITO $ "memExp_evaluate" ++ show count ]

        setToFalse =
          [ PUSH4 $ getStorageAddress MemoryExpressionRefs
          , SLOAD
          , PUSH32 $ integer2w256 $ 2 ^ (2 * count) -- bitmask
          , XOR
          , PUSH4 $ getStorageAddress MemoryExpressionRefs
          , SSTORE
          , JUMPTO $ "memExp_end" ++ show count ]

      in checkIfMemExpIsTrueOrFalse ++ checkIfTimeHasStarted ++ checkIfTimeHasPassed ++ setToFalse

    jumpDestEvaluateExp = [ JUMPDESTFROM $ "memExp_evaluate" ++ show count ]
    evaulateExpression  = evalState (compIExp iExp) (CompileEnv 0 count 0x0 "mem_exp")

     -- eval to false but time not run out: don't set memdibit
    checkEvalResult     = [ ISZERO,
                            JUMPITO $ "memExp_end" ++ show count ]

    setToTrue           = [ PUSH4 $ getStorageAddress MemoryExpressionRefs
                          , SLOAD
                          , PUSH32 $ integer2w256 $ 2 ^ (2 * count + 1) -- bitmask
                          , XOR
                          , PUSH4 $ getStorageAddress MemoryExpressionRefs
                          , SSTORE ]
  in
    checkIfExpShouldBeEvaluated ++
    jumpDestEvaluateExp ++
    evaulateExpression ++
    checkEvalResult ++
    setToTrue ++
    [JUMPDESTFROM $ "memExp_end" ++ show count]

-- Return the code to handle the margin refund as a result of dead
-- branches due to evaluation of memory expressions
-- Happens within a state monad since each element needs an index to
-- identify it in storage s.t. its state can be stored

type MrId = Integer
type MarginCompiler a = State MrId a

newMrId :: MarginCompiler MrId
newMrId = get <* modify (+ 1)

-- This method should compare the bits set in the MemoryExpression word
-- in storage with the path which is the key of the element with which it
-- is called.
-- If we are smart here, we set the entire w32 (256 bit value) to represent
-- a path and load the word and XOR it with what was found in storage
-- This word can be set at compile time
getExecuteMarginRefundM :: MarginRefundMapElement -> MarginCompiler [EvmOpcode]
getExecuteMarginRefundM (path, refunds) = do
  i <- newMrId
  return $ (checkIfMarginHasAlreadyBeenRefunded i) ++ (checkIfPathIsChosen path i) ++ (payBackMargin refunds) ++ (setMarginRefundBit i) ++  [JUMPDESTFROM $ "mr_end" ++ show i]
  where
    -- Skip the rest of the call if the margin has already been repaid
    checkIfMarginHasAlreadyBeenRefunded i =
      [ PUSH32 $ integer2w256 $ 2 ^ ( i + 1 ) -- add 1 since right-most bit is used to indicate an active DC
      , PUSH4 $ getStorageAddress Activated
      , SLOAD
      , AND
      , JUMPITO $ "mr_end" ++ show i
      ]
    -- leaves 1 or 0 on top of stack to show if path is chosen
    -- Only the bits below max index need to match for this path to be chosen
    checkIfPathIsChosen mrme i =
      [ PUSH32 $ integer2w256 $ path2Bitmask mrme
      , PUSH32 $ integer2w256 $ 2 ^ ( 2 * (path2highestIndexValue mrme + 1) ) - 1 -- bitmask to only check lowest bits
      , AND
      , PUSH4 $ getStorageAddress MemoryExpressionRefs
      , SLOAD
      , XOR
      , JUMPITO $ "mr_end" ++ show i -- iff non-zero refund; if 0, refund
      ]
    payBackMargin [] = []
    payBackMargin ((tokenAddr, recipient, amount):ls) = -- push args, call transfer, check ret val
      [ PUSH32 $ address2w256 recipient -- TODO: This hould be PUSH20, not PUSH32. Will save gas.
      , PUSH32 $ address2w256 tokenAddr
      , PUSH32 $ integer2w256 amount
      , FUNCALL "transfer_subroutine"
      , ISZERO,
        JUMPITO "global_throw"
      ] ++ payBackMargin ls
    setMarginRefundBit i =
      [ PUSH32 $ integer2w256 $ 2 ^ (i + 1)
      , PUSH4 $ getStorageAddress Activated
      , SSTORE
      ]

path2Bitmask :: [(Integer, Bool)] -> Integer
path2Bitmask [] = 0
path2Bitmask ((i, branch):ls) = 2 ^ (2 * i + if branch then 1 else 0) + path2Bitmask ls

-- Return highest index value in path, assumes the path is an ordered, asc list. So returns int of last elem
-- TODO: Rewrite this using better language constructs
path2highestIndexValue :: [(Integer, Bool)] -> Integer
path2highestIndexValue [] = 0
path2highestIndexValue ((i, _branch):[]) = i
path2highestIndexValue ((_i, _branch):ls) = path2highestIndexValue ls

-- Returns the code for executing all tcalls that function gets
getExecuteTCs :: [IMemExp] -> [TransferCall] -> [EvmOpcode]
getExecuteTCs mes tcs =
  let
    selfdestruct = [ JUMPDESTFROM "selfdestruct",
                     CALLER,
                     SELFDESTRUCT,
                     STOP ]
  in
    (getExecuteTCsH mes tcs 0) ++
      -- Prevent selfdestruct from running after each call
    [STOP] ++
    selfdestruct

getExecuteTCsH :: [IMemExp] -> [TransferCall] -> Integer -> [EvmOpcode]
getExecuteTCsH mes (tc:tcs) i = (getExecuteTCsHH mes tc i) ++ (getExecuteTCsH mes tcs (i + 1))
getExecuteTCsH _ [] _ = []

-- Compile intermediate expression into EVM opcodes
-- THIS IS THE ONLY PLACE IN THE COMPILER WHERE EXPRESSION ARE HANDLED
compIExp :: IntermediateExpression -> CompileGet [EvmOpcode]
compIExp (ILitExp ilit) = do
  codeEnv <- get
  let mo = memOffset codeEnv
  uniqueLabel <- newLabel "observable"
  return $ compILit ilit mo uniqueLabel
compIExp (IMultExp exp_1 exp_2) = do
  e1 <- compIExp exp_1
  e2 <- compIExp exp_2
  return $ e1 ++ e2 ++ [MUL]
compIExp (ISubtExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [SUB]
compIExp (IAddiExp exp_1 exp_2) = do
  e1 <- compIExp exp_1
  e2 <- compIExp exp_2
  return $ e1 ++ e2 ++ [ADD]
compIExp (IDiviExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [DIV]
compIExp (IEqExp exp_1 exp_2) = do
  e1 <- compIExp exp_1
  e2 <- compIExp exp_2
  return $ e1 ++ e2 ++ [EVM_EQ]
compIExp (ILtExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [EVM_LT]
compIExp (IGtExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [EVM_GT]
compIExp (IGtOrEqExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [EVM_LT, ISZERO]
compIExp (ILtOrEqExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [EVM_GT, ISZERO]
compIExp (IOrExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [OR]
compIExp (IAndExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  return $ e2 ++ e1 ++ [AND]
-- MinExp and MaxExp can also be written without jumps: x^((x^y)&-(x<y))
-- which is cheaper?
compIExp (IMinExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  l0 <- newLabel "min_is_e1"
  return $ e1 ++ e2 ++ [DUP2, DUP2, EVM_GT, JUMPITO l0, SWAP1, JUMPDESTFROM l0, POP]
compIExp (IMaxExp exp_1 exp_2) = do
  e2 <- compIExp exp_2
  e1 <- compIExp exp_1
  l0 <- newLabel "max_is_e1"
  return $ e1 ++ e2 ++ [DUP2, DUP2, EVM_LT, JUMPITO l0, SWAP1, JUMPDESTFROM l0, POP]
compIExp (INotExp exp_1) = do -- e1 is assumed boolean, and is to be checked in type checker.
  e1 <- compIExp exp_1
  return $ e1 ++ [ISZERO]
compIExp (IIfExp exp_1 exp_2 exp_3) = do
  e1        <- compIExp exp_1 -- places 0 or 1 in s[0]
  e2        <- compIExp exp_2
  e3        <- compIExp exp_3
  if_label  <- newLabel "if"
  end_label <- newLabel "end_if_else_exp"
  return $
    e1 ++
    [JUMPITO if_label] ++
    e3 ++
    [JUMPTO end_label] ++
    [JUMPDESTFROM if_label] ++
    e2 ++
    [JUMPDESTFROM end_label]

compILit :: ILiteral -> Integer -> String -> [EvmOpcode]
compILit (IIntVal int) _ _ = [PUSH32 $ integer2w256 int]
compILit (IBoolVal bool) _ _ = if bool then [PUSH1 0x1] else [PUSH1 0x0] -- 0x1 is true
compILit (IObservable address key) memOffset _ =
  let
    functionCall =
      getFunctionCallEvm
        address
        (getFunctionSignature "get(bytes32)")
        (Word256 ( string2w256 key ) : [])
        (fromInteger memOffset)
        (fromInteger memOffset)
        0x20
    moveResToStack = [ PUSH1 $ fromInteger memOffset,
                       MLOAD ]
  in
    functionCall
    ++ moveResToStack

getExecuteTCsHH :: [IMemExp] -> TransferCall -> Integer -> [EvmOpcode]
getExecuteTCsHH mes tc transferCounter =
  let
    checkIfCallShouldBeMade =
      let
        checkIfTimeHasPassed = [ PUSH4 $ getStorageAddress CreationTimestamp,
                                 SLOAD,
                                 TIMESTAMP,
                                 SUB,
                                 PUSH32 $ integer2w256 $ _delay tc,
                                 EVM_GT,
                                 JUMPITO $ "method_end" ++ (show (transferCounter)) ]
        -- Skip tcall if method has been executed already
        -- This only works for less than 2^8 transfer calls
        checkIfTCHasBeenExecuted = [ PUSH4 $ getStorageAddress Executed,
                                     SLOAD,
                                     PUSH1 $ fromInteger transferCounter,
                                     PUSH1 0x2,
                                     EXP,
                                     AND,
                                     ISZERO,
                                     JUMPITO $ "method_end" ++ (show (transferCounter)) ]

            -- This code can be represented with the following C-like code:
            -- if (memdibit == 00b) { GOTO YIELD } // Don't execute and don't set executed bit to zero.
            -- if (memdibit == 10b && !branch || memdibit == 01b && branch ) { GOTO SKIP } // TC should not execute. Update executed bit
            -- if (memdibit == 10b && branch || memdibit == 01b && !branch ) { GOTO PASS } // Check next memExp. If all PASS, then execute.
            -- TODO: the three above code blocks should be placed in an order which optimizes the gas cost over some ensemble of contracts
            -- Obviously, 3! possible orders exist.
        checkIfTcIsInActiveBranches memExpPath = concatMap checkIfTcIsInActiveBranch memExpPath
          where
            checkIfTcIsInActiveBranch (memExpId, branch) =
              let
                yieldStatement = 
                  [ PUSH4 $ getStorageAddress MemoryExpressionRefs
                  , SLOAD
                  , DUP1 -- should be popped in all cases to keep the stack clean
                  -- TODO: WARNING: ATM this value is not being popped!
                  , PUSH32 $ integer2w256 $ 0x3 * 2 ^ (2 * memExpId) -- bitmask
                  , AND
                  , ISZERO
                  , JUMPITO $ "method_end" ++ show transferCounter ] -- GOTO YIELD
                passAndSkipStatement =
                  [ PUSH32 $ integer2w256 $ 2 ^ (2 * memExpId + if branch then 1 else 0) -- bitmask
                  , AND
                  , ISZERO
                  , JUMPITO $ "tc_SKIP" ++ show transferCounter ]
                  -- The fall-through case represents the "PASS" case.
              in
                yieldStatement ++ passAndSkipStatement
      in
        checkIfTimeHasPassed ++
        checkIfTCHasBeenExecuted ++
        checkIfTcIsInActiveBranches (_memExpPath tc)

    callTransferToTcRecipient =
      evalState (compIExp ( _amount tc)) (CompileEnv 0 transferCounter 0x00 "amount_exp")
      ++ [ PUSH32 $ integer2w256 $ _maxAmount tc
         , DUP2
         , DUP2
         , EVM_GT
         , JUMPITO $ "use_exp_res" ++ (show transferCounter)
         , SWAP1
         , JUMPDESTFROM $ "use_exp_res" ++ (show transferCounter)
         , POP]
      ++ [ PUSH32 $ address2w256 (_to tc)
         , PUSH32 $ address2w256 (_tokenAddress tc)
         , DUP3 ]
      ++ [ FUNCALL "transfer_subroutine" ]
      ++ [ ISZERO, JUMPITO "global_throw" ]

    checkIfTransferToTcSenderShouldBeMade =
      [ PUSH32 (integer2w256 (_maxAmount tc))
      , SUB
      , DUP1
      , PUSH1 0x0
      , EVM_EQ
      , JUMPITO $ "skip_call_to_sender" ++ (show transferCounter) ]
      -- TODO: Here, we should call transfer to the
      -- TC originator (transfer back unspent margin)
      -- but we do not want to recalculate the amount
      -- so we should locate the amount on the stack.
      -- And make sure it is preserved on the stack
      -- for the next call to transfer.

    callTransferToTcOriginator =
      [ PUSH32 $ address2w256 (_from tc)
      , PUSH32 $ address2w256 (_tokenAddress tc)
      , DUP3
      , FUNCALL "transfer_subroutine" ]
      ++ [ ISZERO, JUMPITO "global_throw" ] -- check ret val

    -- Flip correct bit from one to zero and call selfdestruct if all tcalls compl.
    skipCallToTcSenderJumpDest = [ JUMPDESTFROM $ "skip_call_to_sender" ++ (show transferCounter)
                                 , POP ] -- pop return amount from stack
    updateExecutedWord = [
      JUMPDESTFROM $ "tc_SKIP" ++ show transferCounter,
      PUSH4 $ getStorageAddress Executed,
      SLOAD,
      PUSH1 $ fromInteger transferCounter,
      PUSH1 0x2,
      EXP,
      XOR,
      DUP1,
      ISZERO,
      JUMPITO "selfdestruct",
      PUSH4 $ getStorageAddress Executed,
      SSTORE ]
    functionEndLabel = [JUMPDESTFROM  $ "method_end" ++ (show transferCounter)]
  in
    checkIfCallShouldBeMade ++
    callTransferToTcRecipient ++
    checkIfTransferToTcSenderShouldBeMade ++
    callTransferToTcOriginator ++
    skipCallToTcSenderJumpDest ++
    updateExecutedWord ++
    functionEndLabel

-- This might have to take place within the state monad to get unique labels for each TransferFrom call
getActivate :: ActivateMap -> [EvmOpcode]
getActivate am = [JUMPDESTFROM "activate_method"]
                 ++ ( concatMap activateMapElementToTransferFromCall $ Map.assocs am )
                 -- set activate bit to 0x01 (true)
                 ++ [ PUSH1 0x01, PUSH4 $ getStorageAddress Activated, SSTORE ]
                 ++ saveTimestampToStorage

activateMapElementToTransferFromCall :: ActivateMapElement -> [EvmOpcode]
activateMapElementToTransferFromCall ((tokenAddress, fromAddress), amount) =
  pushArgsToStack ++ subroutineCall ++ throwIfReturnFalse
  where
    pushArgsToStack =
      [ PUSH32 $ address2w256 $ fromAddress
      , PUSH32 $ address2w256 $ tokenAddress
      , PUSH32 $ integer2w256 $ amount ]
    subroutineCall =
      [ FUNCALL "transferFrom_subroutine" ]
    throwIfReturnFalse = [ ISZERO, JUMPITO "global_throw" ]

getMemExpById :: MemExpId -> [IMemExp] -> IMemExp
getMemExpById memExpId [] = error $ "Could not find IMemExp with ID " ++ show memExpId
getMemExpById memExpId (me:mes) =
  if memExpId == _IMemExpIdent me
    then me
    else getMemExpById memExpId mes

-- We also need to add a check whether the transferFrom function call
-- returns true or false. Only of all function calls return true, should
-- the activated bit be set. This bit has not yet been reserved in
-- memory/defined.



-- TESTS

-- test_EvmOpCodePush1Hex = PUSH1 0x60 :: EvmOpcode
-- test_EvmOpCodePush1Dec = PUSH1 60 :: EvmOpcode

-- -- ppEvm

-- test_ppEvmWithHex = TestCase ( assertEqual "ppEvm with hex input" (ppEvm(test_EvmOpCodePush1Hex)) "6060" )
-- test_ppEvmWithDec = TestCase ( assertEqual "ppEvm with dec input" (ppEvm(test_EvmOpCodePush1Dec)) "603c" )

-- -- getJumpTable

-- test_getJumpTable = TestCase (assertEqual "getJumpTable test" (getJumpTable) ([CALLVALUE,ISZERO,JUMPITO "no_val0",THROW,JUMPDESTFROM "no_val0",STOP]))

-- -- evmCompile

-- exampleContact             = parse' "translate(100, both(scale(101, transfer(EUR, 0xffffffffffffffffffffffffffffffffffffffff, 0x0000000000000000000000000000000000000000)), scale(42, transfer(EUR, 0xffffffffffffffffffffffffffffffffffffffff, 0x0000000000000000000000000000000000000000))))"
-- exampleIntermediateContact = intermediateCompile(exampleContact)

-- test_evmCompile = TestCase( assertEqual "evmCompile test with two contracts" (evmCompile exampleIntermediateContact) (getJumpTable) )

-- -- getOpcodeSize

-- evm_opcode_push1       = PUSH1 0x60 :: EvmOpcode
-- evm_opcode_push4       = PUSH4 0x60606060 :: EvmOpcode
-- evm_opcode_pushJUMPITO = JUMPITO ":)" :: EvmOpcode
-- evm_opcode_pushaADD    = ADD :: EvmOpcode

-- test_getOpcodeSize_push1   = TestCase (assertEqual "test_getOpcodeSize_push1" (getOpcodeSize evm_opcode_push1) (2))
-- test_getOpcodeSize_push4   = TestCase (assertEqual "test_getOpcodeSize_push4" (getOpcodeSize evm_opcode_push4) (5))
-- test_getOpcodeSize_JUMPITO = TestCase (assertEqual "test_getOpcodeSize_JUMPITO" (getOpcodeSize evm_opcode_pushJUMPITO) (6))
-- test_getOpcodeSize_ADD     = TestCase (assertEqual "evm_opcode_pushaADD" (getOpcodeSize evm_opcode_pushaADD) (1))

-- -- linker

-- exampleWithMultipleJumpDest = [JUMPITO "MADS",CALLVALUE,STOP,STOP,JUMPDESTFROM "MADS",ISZERO,JUMPITO "no_val0",THROW,JUMPDESTFROM "no_val0",STOP, JUMPTO "MADS", JUMPITO "MADS"]

-- test_linker_mult_JumpDest = TestCase (assertEqual "test_linker_mult_JumpDest" (linker exampleWithMultipleJumpDest) ([JUMPITOA 10,CALLVALUE,STOP,STOP,JUMPDEST,ISZERO,JUMPITOA 19,THROW,JUMPDEST,STOP,JUMPTOA 10,JUMPITOA 10]))

-- -- replaceLabel

-- test_eliminatePseudoInstructions_mult_JumpDest = TestCase (assertEqual "test_eliminatePseudoInstructions_mult_JumpDest" (eliminatePseudoInstructions $ linker exampleWithMultipleJumpDest) ([PUSH4 10,JUMPI,CALLVALUE,STOP,STOP,JUMPDEST,ISZERO,PUSH4 19,JUMPI,THROW,JUMPDEST,STOP,PUSH4 10,JUMP,PUSH4 10,JUMPI]))

-- -- asmToMachineCode

-- test_asmToMachineCode_easy = TestCase (assertEqual "test_asmToMachineCode_easy" (asmToMachineCode $ eliminatePseudoInstructions $ linker [PUSH1 0x60, STOP, PC]) "60600058")
-- test_asmToMachineCode_hard = TestCase (assertEqual "test_asmToMachineCode_hard" (asmToMachineCode $ eliminatePseudoInstructions $ linker exampleWithMultipleJumpDest) ("630000000a573400005b15630000001357fe5b00630000000a56630000000a57"))

-- tests = TestList [TestLabel "test_ppEvmWithHex" test_ppEvmWithHex,
--                   TestLabel "test_ppEvmWithDec" test_ppEvmWithDec,
--                   TestLabel "test_getJumpTable" test_getJumpTable,
--                   TestLabel "test_evmCompile" test_evmCompile,
--                   TestLabel "test_getOpcodeSize_push1" test_getOpcodeSize_push1,
--                   TestLabel "test_getOpcodeSize_push4" test_getOpcodeSize_push4,
--                   TestLabel "test_getOpcodeSize_JUMPITO" test_getOpcodeSize_JUMPITO,
--                   TestLabel "test_getOpcodeSize_ADD" test_getOpcodeSize_ADD,
--                   TestLabel "test_linker_mult_JumpDest" test_linker_mult_JumpDest,
--                   TestLabel "test_eliminatePseudoInstructions_mult_JumpDest" test_eliminatePseudoInstructions_mult_JumpDest,
--                   TestLabel "test_asmToMachineCode_hard" test_asmToMachineCode_hard,
--                   TestLabel "test_asmToMachineCode_easy" test_asmToMachineCode_easy]
