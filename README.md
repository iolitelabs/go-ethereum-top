
### Makefile
* adding support for creating bootnode
```diff
diff --git a/Makefile b/Makefile
index 3922d60..77f351d 100644
--- a/Makefile
+++ b/Makefile
@@ -16,6 +16,11 @@ geth:
 	@echo "Done building."
 	@echo "Run \"$(GOBIN)/geth\" to launch geth."
 
+bootnode:
+	build/env.sh go run build/ci.go install ./cmd/bootnode
+	@echo "Done building."
+	@echo "Run \"$(GOBIN)/bootnode\" to launch bootnode."
+
 swarm:
 	build/env.sh go run build/ci.go install ./cmd/swarm
 	@echo "Done building."
```
### accounts/abi/bind/backends/simulated.go
* additional logs
```diff
diff --git a/accounts/abi/bind/backends/simulated.go b/accounts/abi/bind/backends/simulated.go
index 2b5c5fc..5362c94 100644
--- a/accounts/abi/bind/backends/simulated.go
+++ b/accounts/abi/bind/backends/simulated.go
@@ -37,6 +37,7 @@ import (
 	"github.com/ethereum/go-ethereum/eth/filters"
 	"github.com/ethereum/go-ethereum/ethdb"
 	"github.com/ethereum/go-ethereum/event"
+	"github.com/ethereum/go-ethereum/log"
 	"github.com/ethereum/go-ethereum/params"
 	"github.com/ethereum/go-ethereum/rpc"
 )
@@ -286,7 +287,7 @@ func (b *SimulatedBackend) callContract(ctx context.Context, call ethereum.CallM
 	// about the transaction and calling mechanisms.
 	vmenv := vm.NewEVM(evmContext, statedb, b.config, vm.Config{})
 	gaspool := new(core.GasPool).AddGas(math.MaxUint64)
-
+	log.Iolite("when simulated? callContract", "msg.Data", msg.Data())
 	return core.NewStateTransition(vmenv, msg, gaspool).TransitionDb()
 }
```
### core/meta/base_meta_executor.go
* MetaExecutor interface base implementation
* **IntrinsicGas()** inherit Ethereum algorithm
```diff 
diff --git a/core/meta/base_meta_executor.go b/core/meta/base_meta_executor.go
new file mode 100644
index 0000000..89eb636
--- /dev/null
+++ b/core/meta/base_meta_executor.go
@@ -0,0 +1,46 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"math"
+
+	"github.com/ethereum/go-ethereum/core/vm"
+	"github.com/ethereum/go-ethereum/params"
+)
+
+type BaseMetaExecutor struct {
+	metadata []byte
+}
+
+// IntrinsicGas computes the 'intrinsic gas' for a message with the given metadata. iolite.TODO: need to rework algorithm
+func (executor *BaseMetaExecutor) IntrinsicGas() (uint64, error) {
+	if len(executor.metadata) == 0 {
+		return 0, nil
+	}
+
+	// Set the starting gas for the raw transaction
+	var gas uint64
+	// Bump the required gas by the amount of transactional data
+	if len(executor.metadata) > 0 {
+		// Zero and non-zero bytes are priced differently
+		var nz uint64
+		for _, byt := range executor.metadata {
+			if byt != 0 {
+				nz++
+			}
+		}
+		// Make sure we don't exceed uint64 for all data combinations
+		if (math.MaxUint64-gas)/params.TxDataNonZeroGas < nz {
+			return 0, vm.ErrOutOfGas
+		}
+		gas += nz * params.TxDataNonZeroGas
+
+		z := uint64(len(executor.metadata)) - nz
+		if (math.MaxUint64-gas)/params.TxDataZeroGas < z {
+			return 0, vm.ErrOutOfGas
+		}
+		gas += z * params.TxDataZeroGas
+	}
+	return gas, nil
+}
```
### core/meta/base_meta_payer.go
* MetaPayer interface base implementation
* **CanPay()** sums up all recipients and compares it with the specified limit
* the result of **IntrinsicGas()** is the product of the number of recipients by **TxGas(21000)**
```diff
diff --git a/core/meta/base_meta_payer.go b/core/meta/base_meta_payer.go
new file mode 100644
index 0000000..c927ba2
--- /dev/null
+++ b/core/meta/base_meta_payer.go
@@ -0,0 +1,52 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+	"github.com/ethereum/go-ethereum/log"
+	"github.com/ethereum/go-ethereum/params"
+)
+
+type BaseMetaPayer struct {
+	from      *common.Address
+	metaLogs  *types.MetaLogs
+	metaLimit *big.Int
+}
+
+func (payer *BaseMetaPayer) CanPay() (*big.Int, bool) {
+	sum := big.NewInt(0)
+
+	if payer.metaLogs == nil || len(payer.metaLogs.Logs()) == 0 {
+		return sum, true
+	}
+
+	for _, log := range payer.metaLogs.Logs() {
+		sum.Add(sum, log.Amount)
+	}
+
+	log.Iolite("CanPay", "sum", sum, "metaLimit", payer.metaLimit)
+	if sum.Cmp(payer.metaLimit) > 0 {
+		return sum, false
+	}
+
+	return sum, true
+}
+
+func (payer *BaseMetaPayer) IntrinsicGas() (uint64, error) {
+	count := uint64(len(payer.metaLogs.Logs()))
+	if payer.metaLogs == nil || count == 0 {
+		return 0, nil
+	}
+
+	gas := count * params.TxGas
+	if gas/count != params.TxGas {
+		return 0, vm.ErrOutOfGas
+	}
+
+	return gas, nil
+}
```
### core/meta/business_meta_executor.go
* Business implementation of MetaExecutor interface 
* Executes the metadata code in the EVM without changing the state
* Compiles a list of recipients and their values
```diff
diff --git a/core/meta/business_meta_executor.go b/core/meta/business_meta_executor.go
new file mode 100644
index 0000000..c68083a
--- /dev/null
+++ b/core/meta/business_meta_executor.go
@@ -0,0 +1,65 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"errors"
+	"math"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+	"github.com/ethereum/go-ethereum/log"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+type BusinessMetaExecutor struct {
+	BaseMetaExecutor
+
+	readEVM *vm.EVM
+	from    common.Address
+}
+
+func (executor *BusinessMetaExecutor) Execute() (*types.MetaLogs, error) {
+	metadata := new(types.BusinessMetadata)
+	metalogs := new(types.MetaLogs)
+
+	if len(executor.metadata) == 0 {
+		return metalogs, nil
+	}
+
+	if executor.readEVM == nil {
+		return metalogs, errors.New("the runtime is not specified")
+	}
+
+	if err := rlp.DecodeBytes(executor.metadata, metadata); err != nil {
+		return metalogs, err
+	}
+
+	log.Iolite("Business Metadata", "metadata", metadata)
+
+	sender := vm.AccountRef(executor.from)
+
+	ret, _, vmerr := executor.readEVM.Call(sender, *metadata.Data().Buisness, metadata.Data().Input, math.MaxUint64/2, big.NewInt(0))
+	if vmerr != nil {
+		return metalogs, vmerr
+	}
+
+	log.Iolite("Executed Metadata", "ret", ret)
+
+	if len(ret) != 64 {
+		return metalogs, errors.New("the business call result does not match the format (address, uint256)")
+	}
+
+	metalogs.Push(common.BytesToAddress(ret[:32]), big.NewInt(0).SetBytes(ret[32:]))
+
+	for _, data := range metalogs.Logs() {
+		log.Iolite("Decoded Metalogs", "To", data.Recipient, "Value", data.Amount)
+	}
+	return metalogs, nil
+}
+
+func NewBusinessMetaExecutor(metadata []byte, readEVM *vm.EVM, from common.Address) *BusinessMetaExecutor {
+	return &BusinessMetaExecutor{BaseMetaExecutor{metadata}, readEVM, from}
+}
```
### core/meta/business_meta_payer.go
* Business implementation of MetaPayer interface 
* Pay off with the recipients through the EVM function call
```diff
diff --git a/core/meta/business_meta_payer.go b/core/meta/business_meta_payer.go
new file mode 100644
index 0000000..b3d6f43
--- /dev/null
+++ b/core/meta/business_meta_payer.go
@@ -0,0 +1,60 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"errors"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/log"
+
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+)
+
+type BusinessMetaPayer struct {
+	BaseMetaPayer
+
+	evm *vm.EVM
+}
+
+func tryPay(from *common.Address, metaLogs *types.MetaLogs, evm *vm.EVM, gas uint64) (uint64, error) {
+	if evm == nil {
+		return gas, errors.New("the runtime is not specified")
+	}
+
+	var vmerr error
+	gasLeft := gas
+	sender := vm.AccountRef(*from)
+	for _, metalog := range metaLogs.Logs() {
+		_, gasLeft, vmerr = evm.Call(sender, *metalog.Recipient, []byte{}, gasLeft, metalog.Amount) // iolite.TODO need the correct gas calculation
+		log.Iolite("tryPay", "gas", gas, "gasLeft", gasLeft, "gasUsed", gas-gasLeft)
+		if vmerr != nil {
+			return gasLeft, vmerr
+		}
+	}
+	return gasLeft, nil
+}
+
+func (payer *BusinessMetaPayer) Pay(gas uint64) (*big.Int, uint64, error) {
+	if len(payer.metaLogs.Logs()) > 1 {
+		return big.NewInt(0), gas, errors.New("only one recipient is allowed for business call")
+	}
+
+	sum, payable := payer.CanPay()
+	if !payable {
+		return big.NewInt(0), gas, vm.ErrInsufficientBalance
+	}
+
+	gasLeft, err := tryPay(payer.from, payer.metaLogs, payer.evm, gas)
+	if err != nil {
+		return big.NewInt(0), gasLeft, err
+	}
+
+	return sum, gasLeft, nil
+}
+
+func NewBusinessMetaPayer(from common.Address, metaLogs *types.MetaLogs, metaLimit *big.Int, evm *vm.EVM) *BusinessMetaPayer {
+	return &BusinessMetaPayer{BaseMetaPayer{&from, metaLogs, metaLimit}, evm}
+}
```
### core/meta/meta_executor.go
* Interface for working with metadata
```diff
diff --git a/core/meta/meta_executor.go b/core/meta/meta_executor.go
new file mode 100644
index 0000000..c66b7c5
--- /dev/null
+++ b/core/meta/meta_executor.go
@@ -0,0 +1,11 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import "github.com/ethereum/go-ethereum/core/types"
+
+type MetaExecutor interface {
+	Execute() (*types.MetaLogs, error)
+
+	IntrinsicGas() (uint64, error)
+}
```
### core/meta/meta_payer.go
* Interface for working with metadata
```diff
diff --git a/core/meta/meta_payer.go b/core/meta/meta_payer.go
new file mode 100644
index 0000000..17f9742
--- /dev/null
+++ b/core/meta/meta_payer.go
@@ -0,0 +1,13 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import "math/big"
+
+type MetaPayer interface {
+	Pay(gas uint64) (*big.Int, uint64, error)
+
+	CanPay() (*big.Int, bool)
+
+	IntrinsicGas() (uint64, error)
+}
```
### core/meta/simple_meta_executor.go
* **(Depreciated)** Simple implementation of MetaExecutor interface
```diff
diff --git a/core/meta/simple_meta_executor.go b/core/meta/simple_meta_executor.go
new file mode 100644
index 0000000..fa9f070
--- /dev/null
+++ b/core/meta/simple_meta_executor.go
@@ -0,0 +1,34 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/log"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+type SimpleMetaExecutor struct {
+	BaseMetaExecutor
+}
+
+func (executor *SimpleMetaExecutor) Execute() (*types.MetaLogs, error) {
+	meta := new(types.MetaLogs)
+
+	if len(executor.metadata) == 0 {
+		return meta, nil
+	}
+
+	if err := rlp.DecodeBytes(executor.metadata, meta); err != nil {
+		return meta, err
+	}
+
+	for _, data := range meta.Logs() {
+		log.Iolite("Decoded Metadata", "To", data.Recipient, "Value", data.Amount)
+	}
+	return meta, nil
+}
+
+func NewSimpleMetaExecutor(metadata []byte) *SimpleMetaExecutor {
+	return &SimpleMetaExecutor{BaseMetaExecutor{metadata}}
+}
```
### core/meta/simple_meta_payer.go
* **(Depreciated)** Simple implementation of MetaPayer interface
```diff
diff --git a/core/meta/simple_meta_payer.go b/core/meta/simple_meta_payer.go
new file mode 100644
index 0000000..1cdc717
--- /dev/null
+++ b/core/meta/simple_meta_payer.go
@@ -0,0 +1,36 @@
+// Copyright 2018 ... iolite.TODO
+
+package meta
+
+import (
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+)
+
+type SimpleMetaPayer struct {
+	BaseMetaPayer
+
+	state vm.StateDB
+}
+
+func (payer *SimpleMetaPayer) Pay(gas uint64) (*big.Int, uint64, error) {
+	sum, payable := payer.CanPay()
+	if !payable {
+		return big.NewInt(0), 0, vm.ErrInsufficientBalance
+	}
+
+	for _, log := range payer.metaLogs.Logs() {
+		payer.state.AddBalance(*log.Recipient, log.Amount)
+		payer.state.SubBalance(*payer.from, log.Amount)
+	}
+
+	return sum, 0, nil
+}
+
+func NewSimpleMetaPayer(from common.Address, metaLogs *types.MetaLogs, metaLimit *big.Int, state vm.StateDB) *SimpleMetaPayer {
+	return &SimpleMetaPayer{BaseMetaPayer{&from, metaLogs, metaLimit}, state}
+}
```
### core/meta_util.go
* Contains additional functions for working with metadata
```diff
diff --git a/core/meta_util.go b/core/meta_util.go
new file mode 100644
index 0000000..3c493a0
--- /dev/null
+++ b/core/meta_util.go
@@ -0,0 +1,113 @@
+// Copyright 2018 ... iolite.TODO
+
+package core
+
+import (
+	"errors"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/math"
+	"github.com/ethereum/go-ethereum/core/meta"
+	"github.com/ethereum/go-ethereum/core/state"
+	"github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+	"github.com/ethereum/go-ethereum/log"
+)
+
+var (
+	ErrMetaInsufficientFunds = errors.New("insufficient funds for metadata payment or payment are not allowed")
+
+	ErrMetaIntrinsicGas = errors.New("metadata intrinsic gas error")
+)
+
+// iolite.TODO do something with code duplication
+
+func UnpackSimpleMetadata(from common.Address, metadata []byte, metaLimit *big.Int, state vm.StateDB) (payer meta.MetaPayer, metaLogs *types.MetaLogs, payment *big.Int, intrinsicGas uint64, err error) {
+	log.Iolite("UnpackSimpleMetadata", "metaLimit", metaLimit)
+
+	executor := meta.NewSimpleMetaExecutor(metadata)
+
+	executorGas, err := executor.IntrinsicGas()
+	if err != nil {
+		return nil, nil, nil, 0, err
+	}
+
+	metaLogs, err = executor.Execute()
+	if err != nil {
+		return nil, metaLogs, nil, 0, err
+	}
+
+	payer = meta.NewSimpleMetaPayer(from, metaLogs, metaLimit, state)
+
+	payerGas, err := payer.IntrinsicGas()
+	if err != nil {
+		return nil, nil, nil, 0, err
+	}
+
+	payment, payable := payer.CanPay()
+	if !payable {
+		return nil, nil, nil, 0, ErrMetaInsufficientFunds
+	}
+
+	intrinsicGas = executorGas + payerGas
+	// Make sure we don't exceed uint64
+	if intrinsicGas < executorGas {
+		return nil, nil, nil, 0, ErrMetaIntrinsicGas
+	}
+
+	return payer, metaLogs, payment, intrinsicGas, nil
+}
+
+func UnpackBusinessMetadata(from common.Address, metadata []byte, metaLimit *big.Int, writeEVM *vm.EVM, readEVM *vm.EVM) (payer meta.MetaPayer, metaLogs *types.MetaLogs, payment *big.Int, intrinsicGas uint64, err error) {
+	log.Iolite("UnpackBusinessMetadata", "metaLimit", metaLimit)
+
+	executor := meta.NewBusinessMetaExecutor(metadata, readEVM, from)
+
+	executorGas, err := executor.IntrinsicGas()
+	if err != nil {
+		return nil, nil, nil, 0, err
+	}
+
+	metaLogs, err = executor.Execute()
+	if err != nil {
+		return nil, metaLogs, nil, 0, err
+	}
+
+	payer = meta.NewBusinessMetaPayer(from, metaLogs, metaLimit, writeEVM)
+
+	payerGas, err := payer.IntrinsicGas()
+	if err != nil {
+		return nil, nil, nil, 0, err
+	}
+
+	payment, payable := payer.CanPay()
+	if !payable {
+		return nil, nil, nil, 0, ErrMetaInsufficientFunds
+	}
+
+	intrinsicGas = executorGas + payerGas
+	// Make sure we don't exceed uint64
+	if intrinsicGas < executorGas {
+		return nil, nil, nil, 0, ErrMetaIntrinsicGas
+	}
+
+	return payer, metaLogs, payment, intrinsicGas, nil
+}
+
+func CreateReadOnlyEVMCopy(evm *vm.EVM, from common.Address) *vm.EVM {
+	statedb, ok := evm.StateDB.(*state.StateDB)
+	statedbCpy := statedb.Copy()
+	statedbCpy.SetBalance(from, math.MaxBig256)
+	log.Iolite("CREATE_STATE", "ok", ok)
+
+	return vm.NewEVM(evm.Context, statedbCpy, evm.ChainConfig(), vm.Config{})
+}
+
+func CreateReadOnlyEVM(msg types.Message, chain *BlockChain, statedb *state.StateDB) *vm.EVM {
+	statedbCpy := statedb.Copy()
+	header := chain.CurrentBlock().Header()
+	context := NewEVMContext(msg, header, chain, nil)
+	statedbCpy.SetBalance(msg.From(), math.MaxBig256)
+	return vm.NewEVM(context, statedbCpy, chain.Config(), vm.Config{})
+}
```
### core/state_processor.go
* Support of extra metadata fields
* additional logs
```diff
diff --git a/core/state_processor.go b/core/state_processor.go
index 4dc58b9..b5e1f83 100644
--- a/core/state_processor.go
+++ b/core/state_processor.go
@@ -18,12 +18,14 @@ package core
 
 import (
 	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
 	"github.com/ethereum/go-ethereum/consensus"
 	"github.com/ethereum/go-ethereum/consensus/misc"
 	"github.com/ethereum/go-ethereum/core/state"
 	"github.com/ethereum/go-ethereum/core/types"
 	"github.com/ethereum/go-ethereum/core/vm"
 	"github.com/ethereum/go-ethereum/crypto"
+	"github.com/ethereum/go-ethereum/log"
 	"github.com/ethereum/go-ethereum/params"
 )
 
@@ -96,7 +98,7 @@ func ApplyTransaction(config *params.ChainConfig, bc *BlockChain, author *common
 	// about the transaction and calling mechanisms.
 	vmenv := vm.NewEVM(context, statedb, config, cfg)
 	// Apply the transaction to the current state (included in the env)
-	_, gas, failed, err := ApplyMessage(vmenv, msg, gp)
+	meta, _, gas, metaGas, failed, err := ApplyMessage(vmenv, msg, gp)
 	if err != nil {
 		return nil, 0, err
 	}
@@ -114,13 +116,15 @@ func ApplyTransaction(config *params.ChainConfig, bc *BlockChain, author *common
 	receipt := types.NewReceipt(root, failed, *usedGas)
 	receipt.TxHash = tx.Hash()
 	receipt.GasUsed = gas
+	receipt.MetaGasUsed = metaGas
 	// if the transaction created a contract, store the creation address in the receipt.
 	if msg.To() == nil {
 		receipt.ContractAddress = crypto.CreateAddress(vmenv.Context.Origin, tx.Nonce())
 	}
 	// Set the receipt logs and create a bloom for filtering
 	receipt.Logs = statedb.GetLogs(tx.Hash())
+	receipt.MetaLogs = meta.Logs()
 	receipt.Bloom = types.CreateBloom(types.Receipts{receipt})
-
+	log.Iolite("ApplyTransaction", "metadata", hexutil.Encode(msg.Metadata()))
 	return receipt, gas, err
 }
```
### core/state_transition.go
* Support of extra metadata fields
* Backward compatibility with Ethereum transactions
* additional logs
```diff
diff --git a/core/state_transition.go b/core/state_transition.go
index 5654cd0..b268014 100644
--- a/core/state_transition.go
+++ b/core/state_transition.go
@@ -22,6 +22,9 @@ import (
 	"math/big"
 
 	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/core/meta"
+	"github.com/ethereum/go-ethereum/core/types"
 	"github.com/ethereum/go-ethereum/core/vm"
 	"github.com/ethereum/go-ethereum/log"
 	"github.com/ethereum/go-ethereum/params"
@@ -73,6 +76,8 @@ type Message interface {
 	Nonce() uint64
 	CheckNonce() bool
 	Data() []byte
+	Metadata() []byte
+	MetadataLimit() *big.Int
 }
 
 // IntrinsicGas computes the 'intrinsic gas' for a message with the given data.
@@ -128,7 +133,7 @@ func NewStateTransition(evm *vm.EVM, msg Message, gp *GasPool) *StateTransition
 // the gas used (which includes gas refunds) and an error if it failed. An error always
 // indicates a core error meaning that the message would always fail for that particular
 // state and would never be accepted within a block.
-func ApplyMessage(evm *vm.EVM, msg Message, gp *GasPool) ([]byte, uint64, bool, error) {
+func ApplyMessage(evm *vm.EVM, msg Message, gp *GasPool) (*types.MetaLogs, []byte, uint64, uint64, bool, error) {
 	return NewStateTransition(evm, msg, gp).TransitionDb()
 }
 
@@ -180,7 +185,7 @@ func (st *StateTransition) preCheck() error {
 // TransitionDb will transition the state by applying the current message and
 // returning the result including the the used gas. It returns an error if it
 // failed. An error indicates a consensus issue.
-func (st *StateTransition) TransitionDb() (ret []byte, usedGas uint64, failed bool, err error) {
+func (st *StateTransition) TransitionDb() (metalogs *types.MetaLogs, ret []byte, usedGas uint64, metaGasUsed uint64, failed bool, err error) {
 	if err = st.preCheck(); err != nil {
 		return
 	}
@@ -188,14 +193,31 @@ func (st *StateTransition) TransitionDb() (ret []byte, usedGas uint64, failed bo
 	sender := vm.AccountRef(msg.From())
 	homestead := st.evm.ChainConfig().IsHomestead(st.evm.BlockNumber)
 	contractCreation := msg.To() == nil
+	log.Iolite("ApplyMessage", "metadata", hexutil.Encode(st.msg.Metadata()), "limit", st.msg.MetadataLimit())
+
+	readEVM := CreateReadOnlyEVMCopy(st.evm, msg.From())
+	payer, metalogs, _, metaGas, err := UnpackBusinessMetadata(msg.From(), msg.Metadata(), msg.MetadataLimit(), st.evm, readEVM)
+	// payer, metalogs, _, metaGas, err := UnpackSimpleMetadata(msg.From(), msg.Metadata(), msg.MetadataLimit(), st.state)
+	if err != nil {
+		return nil, nil, 0, 0, false, err
+	}
 
 	// Pay intrinsic gas
-	gas, err := IntrinsicGas(st.data, contractCreation, homestead)
+	txGas, err := IntrinsicGas(st.data, contractCreation, homestead)
 	if err != nil {
-		return nil, 0, false, err
+		return nil, nil, 0, 0, false, err
+	}
+
+	gas := txGas + metaGas
+	// Make sure we don't exceed uint64
+	if gas < txGas {
+		return nil, nil, 0, 0, false, vm.ErrOutOfGas
 	}
+
+	log.Iolite("ApplyMessage", "gas", txGas, "metaGas", metaGas, "fullGas", gas)
+
 	if err = st.useGas(gas); err != nil {
-		return nil, 0, false, err
+		return nil, nil, 0, 0, false, err
 	}
 
 	var (
@@ -203,28 +225,51 @@ func (st *StateTransition) TransitionDb() (ret []byte, usedGas uint64, failed bo
 		// vm errors do not effect consensus and are therefor
 		// not assigned to err, except for insufficient balance
 		// error.
-		vmerr error
+		vmerr             error
+		vmerr2            error
+		beforeMetaGasUsed uint64
 	)
-	if contractCreation {
-		ret, _, st.gas, vmerr = evm.Create(sender, st.data, st.gas, st.value)
+
+	// if the business contract call is not correct, then the transaction will be considered a failure,
+	// but the logic of the pure transaction will be executed
+	tryPayer := meta.NewBusinessMetaPayer(msg.From(), metalogs, msg.MetadataLimit(), readEVM)
+	_, _, vmerr2 = tryPayer.Pay(metaGas)
+
+	if vmerr2 == nil {
+		log.Iolite("evm.before", "gas", st.gas)
+		if contractCreation {
+			ret, _, st.gas, vmerr = evm.Create(sender, st.data, st.gas, st.value)
+		} else {
+			// Increment the nonce for the next transaction
+			st.state.SetNonce(msg.From(), st.state.GetNonce(sender.Address())+1)
+			ret, st.gas, vmerr = evm.Call(sender, st.to(), st.data, st.gas, st.value)
+		}
+		log.Iolite("evm.after", "err", vmerr, "gas", st.gas)
+		if vmerr != nil {
+			log.Debug("VM returned with error", "err", vmerr)
+			// The only possible consensus-error would be if there wasn't
+			// sufficient balance to make the transfer happen. The first
+			// balance transfer may never fail.
+			if vmerr == vm.ErrInsufficientBalance {
+				return nil, nil, 0, 0, false, vmerr
+			}
+		}
+
+		beforeMetaGasUsed = st.gasUsed()
+		log.Iolite("payer.Pay.before", "gas", st.gas)
+		_, st.gas, vmerr2 = payer.Pay(st.gas)
+		log.Iolite("payer.Pay.after", "err", vmerr2, "gas", st.gas)
+		// iolite.TODO check vmerr == vm.ErrInsufficientBalance ?
 	} else {
-		// Increment the nonce for the next transaction
 		st.state.SetNonce(msg.From(), st.state.GetNonce(sender.Address())+1)
-		ret, st.gas, vmerr = evm.Call(sender, st.to(), st.data, st.gas, st.value)
-	}
-	if vmerr != nil {
-		log.Debug("VM returned with error", "err", vmerr)
-		// The only possible consensus-error would be if there wasn't
-		// sufficient balance to make the transfer happen. The first
-		// balance transfer may never fail.
-		if vmerr == vm.ErrInsufficientBalance {
-			return nil, 0, false, vmerr
-		}
+		log.Iolite("check before exec", "err", vmerr2)
 	}
 	st.refundGas()
 	st.state.AddBalance(st.evm.Coinbase, new(big.Int).Mul(new(big.Int).SetUint64(st.gasUsed()), st.gasPrice))
 
-	return ret, st.gasUsed(), vmerr != nil, err
+	metaGasUsed = metaGas + st.gasUsed() - beforeMetaGasUsed
+	log.Iolite("metags???", "gasUsed diff", metaGasUsed)
+	return metalogs, ret, st.gasUsed(), metaGasUsed, vmerr != nil || vmerr2 != nil, err
 }
 
 func (st *StateTransition) refundGas() {
```
### core/tx_pool.go
* Support of extra metadata fields
* additional logs
```diff
diff --git a/core/tx_pool.go b/core/tx_pool.go
index a554f66..1da68f1 100644
--- a/core/tx_pool.go
+++ b/core/tx_pool.go
@@ -581,16 +581,40 @@ func (pool *TxPool) validateTx(tx *types.Transaction, local bool) error {
 	if pool.currentState.GetNonce(from) > tx.Nonce() {
 		return ErrNonceTooLow
 	}
+
+	msg, err := tx.AsMessage(pool.signer)
+	if err != nil {
+		return ErrInvalidSender
+	}
+
+	readEVM := CreateReadOnlyEVM(msg, pool.chain.(*BlockChain), pool.currentState)
+	_, _, payment, metaGas, err := UnpackBusinessMetadata(from, tx.Metadata(), tx.MetadataLimit(), nil, readEVM)
+	// _, _, payment, metaGas, err := UnpackSimpleMetadata(from, tx.Metadata(), tx.MetadataLimit(), nil)
+	if err != nil {
+		return err
+	}
 	// Transactor should have enough funds to cover the costs
 	// cost == V + GP * GL
-	if pool.currentState.GetBalance(from).Cmp(tx.Cost()) < 0 {
+	txCost := big.NewInt(0)
+	txCost.Add(txCost, tx.Cost())
+	txCost.Add(txCost, payment)
+
+	if pool.currentState.GetBalance(from).Cmp(txCost) < 0 {
 		return ErrInsufficientFunds
 	}
+
 	intrGas, err := IntrinsicGas(tx.Data(), tx.To() == nil, pool.homestead)
 	if err != nil {
 		return err
 	}
-	if tx.Gas() < intrGas {
+
+	gas := intrGas + metaGas
+	// Make sure we don't exceed uint64
+	if gas < intrGas {
+		return ErrIntrinsicGas
+	}
+
+	if tx.Gas() < gas {
 		return ErrIntrinsicGas
 	}
 	return nil
@@ -608,12 +632,12 @@ func (pool *TxPool) add(tx *types.Transaction, local bool) (bool, error) {
 	// If the transaction is already known, discard it
 	hash := tx.Hash()
 	if pool.all[hash] != nil {
-		log.Trace("Discarding already known transaction", "hash", hash)
+		log.Warn("Discarding already known transaction", "hash", hash)
 		return false, fmt.Errorf("known transaction: %x", hash)
 	}
 	// If the transaction fails basic validation, discard it
 	if err := pool.validateTx(tx, local); err != nil {
-		log.Trace("Discarding invalid transaction", "hash", hash, "err", err)
+		log.Warn("Discarding invalid transaction", "hash", hash, "err", err)
 		invalidTxCounter.Inc(1)
 		return false, err
 	}
@@ -621,14 +645,14 @@ func (pool *TxPool) add(tx *types.Transaction, local bool) (bool, error) {
 	if uint64(len(pool.all)) >= pool.config.GlobalSlots+pool.config.GlobalQueue {
 		// If the new transaction is underpriced, don't accept it
 		if pool.priced.Underpriced(tx, pool.locals) {
-			log.Trace("Discarding underpriced transaction", "hash", hash, "price", tx.GasPrice())
+			log.Warn("Discarding underpriced transaction", "hash", hash, "price", tx.GasPrice())
 			underpricedTxCounter.Inc(1)
 			return false, ErrUnderpriced
 		}
 		// New transaction is better than our worse ones, make room for it
 		drop := pool.priced.Discard(len(pool.all)-int(pool.config.GlobalSlots+pool.config.GlobalQueue-1), pool.locals)
 		for _, tx := range drop {
-			log.Trace("Discarding freshly underpriced transaction", "hash", tx.Hash(), "price", tx.GasPrice())
+			log.Warn("Discarding freshly underpriced transaction", "hash", tx.Hash(), "price", tx.GasPrice())
 			underpricedTxCounter.Inc(1)
 			pool.removeTx(tx.Hash(), false)
 		}
@@ -652,7 +676,7 @@ func (pool *TxPool) add(tx *types.Transaction, local bool) (bool, error) {
 		pool.priced.Put(tx)
 		pool.journalTx(from, tx)
 
-		log.Trace("Pooled new executable transaction", "hash", hash, "from", from, "to", tx.To())
+		log.Warn("Pooled new executable transaction", "hash", hash, "from", from, "to", tx.To())
 
 		// We've directly injected a replacement transaction, notify subsystems
 		go pool.txFeed.Send(TxPreEvent{tx})
@@ -670,7 +694,7 @@ func (pool *TxPool) add(tx *types.Transaction, local bool) (bool, error) {
 	}
 	pool.journalTx(from, tx)
 
-	log.Trace("Pooled new future transaction", "hash", hash, "from", from, "to", tx.To())
+	log.Warn("Pooled new future transaction", "hash", hash, "from", from, "to", tx.To())
 	return replace, nil
 }
 
@@ -784,9 +808,9 @@ func (pool *TxPool) AddRemotes(txs []*types.Transaction) []error {
 func (pool *TxPool) addTx(tx *types.Transaction, local bool) error {
 	pool.mu.Lock()
 	defer pool.mu.Unlock()
-
 	// Try to inject the transaction and update any state
 	replace, err := pool.add(tx, local)
+	log.Iolite("TxPool", "addTx.err", err)
 	if err != nil {
 		return err
 	}
```
### /core/types/business_metadata.go
* Type describing the **Businnes** metadata structure
```diff
diff --git a/core/types/business_metadata.go b/core/types/business_metadata.go
new file mode 100644
index 0000000..0913d13
--- /dev/null
+++ b/core/types/business_metadata.go
@@ -0,0 +1,39 @@
+// Copyright 2018 ... iolite.TODO
+
+package types
+
+import (
+	"io"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+//go:generate gencodec -type metadata -field-override metadataMarshaling -out gen_metadata_json.go
+
+// Metadata
+type BusinessMetadata struct {
+	data metadata
+}
+
+type metadata struct {
+	Buisness *common.Address `json:"to"    gencodec:"required"`
+	Input    []byte          `json:"input" gencodec:"required"`
+}
+
+type metadataMarshaling struct {
+	Input hexutil.Bytes
+}
+
+// EncodeRLP implements rlp.Encoder
+func (meta *BusinessMetadata) EncodeRLP(w io.Writer) error {
+	return rlp.Encode(w, &meta.data)
+}
+
+// DecodeRLP implements rlp.Decoder
+func (meta *BusinessMetadata) DecodeRLP(s *rlp.Stream) error {
+	return s.Decode(&meta.data)
+}
+
+func (meta *BusinessMetadata) Data() *metadata { return &meta.data }
```
### core/types/gen_header_json.go
* generated file
```diff
diff --git a/core/types/gen_header_json.go b/core/types/gen_header_json.go
index 1b92cd9..1e832f2 100644
--- a/core/types/gen_header_json.go
+++ b/core/types/gen_header_json.go
@@ -13,6 +13,7 @@ import (
 
 var _ = (*headerMarshaling)(nil)
 
+// MarshalJSON marshals as JSON.
 func (h Header) MarshalJSON() ([]byte, error) {
 	type Header struct {
 		ParentHash  common.Hash    `json:"parentHash"       gencodec:"required"`
@@ -52,6 +53,7 @@ func (h Header) MarshalJSON() ([]byte, error) {
 	return json.Marshal(&enc)
 }
 
+// UnmarshalJSON unmarshals from JSON.
 func (h *Header) UnmarshalJSON(input []byte) error {
 	type Header struct {
 		ParentHash  *common.Hash    `json:"parentHash"       gencodec:"required"`
```
```diff
diff --git a/core/types/gen_log_json.go b/core/types/gen_log_json.go
index 1b5ae3c..6e94339 100644
--- a/core/types/gen_log_json.go
+++ b/core/types/gen_log_json.go
@@ -12,6 +12,7 @@ import (
 
 var _ = (*logMarshaling)(nil)
 
+// MarshalJSON marshals as JSON.
 func (l Log) MarshalJSON() ([]byte, error) {
 	type Log struct {
 		Address     common.Address `json:"address" gencodec:"required"`
@@ -37,6 +38,7 @@ func (l Log) MarshalJSON() ([]byte, error) {
 	return json.Marshal(&enc)
 }
 
+// UnmarshalJSON unmarshals from JSON.
 func (l *Log) UnmarshalJSON(input []byte) error {
 	type Log struct {
 		Address     *common.Address `json:"address" gencodec:"required"`
```
### core/types/gen_metadata_json.go
* generated file
```diff
diff --git a/core/types/gen_metadata_json.go b/core/types/gen_metadata_json.go
new file mode 100644
index 0000000..b88be61
--- /dev/null
+++ b/core/types/gen_metadata_json.go
@@ -0,0 +1,46 @@
+// Code generated by github.com/fjl/gencodec. DO NOT EDIT.
+
+package types
+
+import (
+	"encoding/json"
+	"errors"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+)
+
+var _ = (*metadataMarshaling)(nil)
+
+// MarshalJSON marshals as JSON.
+func (m metadata) MarshalJSON() ([]byte, error) {
+	type metadata struct {
+		Buisness *common.Address `json:"to"    gencodec:"required"`
+		Input    hexutil.Bytes   `json:"input" gencodec:"required"`
+	}
+	var enc metadata
+	enc.Buisness = m.Buisness
+	enc.Input = m.Input
+	return json.Marshal(&enc)
+}
+
+// UnmarshalJSON unmarshals from JSON.
+func (m *metadata) UnmarshalJSON(input []byte) error {
+	type metadata struct {
+		Buisness *common.Address `json:"to"    gencodec:"required"`
+		Input    *hexutil.Bytes  `json:"input" gencodec:"required"`
+	}
+	var dec metadata
+	if err := json.Unmarshal(input, &dec); err != nil {
+		return err
+	}
+	if dec.Buisness == nil {
+		return errors.New("missing required field 'to' for metadata")
+	}
+	m.Buisness = dec.Buisness
+	if dec.Input == nil {
+		return errors.New("missing required field 'input' for metadata")
+	}
+	m.Input = *dec.Input
+	return nil
+}
```
### core/types/gen_metalog_json.go
* generated file
```diff
diff --git a/core/types/gen_metalog_json.go b/core/types/gen_metalog_json.go
new file mode 100644
index 0000000..be79f88
--- /dev/null
+++ b/core/types/gen_metalog_json.go
@@ -0,0 +1,47 @@
+// Code generated by github.com/fjl/gencodec. DO NOT EDIT.
+
+package types
+
+import (
+	"encoding/json"
+	"errors"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+)
+
+var _ = (*metalogMarshaling)(nil)
+
+// MarshalJSON marshals as JSON.
+func (m MetaLog) MarshalJSON() ([]byte, error) {
+	type MetaLog struct {
+		Recipient *common.Address `json:"to"    gencodec:"required"`
+		Amount    *hexutil.Big    `json:"value" gencodec:"required"`
+	}
+	var enc MetaLog
+	enc.Recipient = m.Recipient
+	enc.Amount = (*hexutil.Big)(m.Amount)
+	return json.Marshal(&enc)
+}
+
+// UnmarshalJSON unmarshals from JSON.
+func (m *MetaLog) UnmarshalJSON(input []byte) error {
+	type MetaLog struct {
+		Recipient *common.Address `json:"to"    gencodec:"required"`
+		Amount    *hexutil.Big    `json:"value" gencodec:"required"`
+	}
+	var dec MetaLog
+	if err := json.Unmarshal(input, &dec); err != nil {
+		return err
+	}
+	if dec.Recipient == nil {
+		return errors.New("missing required field 'to' for MetaLog")
+	}
+	m.Recipient = dec.Recipient
+	if dec.Amount == nil {
+		return errors.New("missing required field 'value' for MetaLog")
+	}
+	m.Amount = (*big.Int)(dec.Amount)
+	return nil
+}
```
### core/types/gen_receipt_json.go
* generated file
```diff
diff --git a/core/types/gen_receipt_json.go b/core/types/gen_receipt_json.go
index c297ade..9018eaa 100644
--- a/core/types/gen_receipt_json.go
+++ b/core/types/gen_receipt_json.go
@@ -12,6 +12,7 @@ import (
 
 var _ = (*receiptMarshaling)(nil)
 
+// MarshalJSON marshals as JSON.
 func (r Receipt) MarshalJSON() ([]byte, error) {
 	type Receipt struct {
 		PostState         hexutil.Bytes  `json:"root"`
@@ -19,9 +20,11 @@ func (r Receipt) MarshalJSON() ([]byte, error) {
 		CumulativeGasUsed hexutil.Uint64 `json:"cumulativeGasUsed" gencodec:"required"`
 		Bloom             Bloom          `json:"logsBloom"         gencodec:"required"`
 		Logs              []*Log         `json:"logs"              gencodec:"required"`
+		MetaLogs          []*MetaLog     `json:"metaLogs"          gencodec:"required"`
 		TxHash            common.Hash    `json:"transactionHash" gencodec:"required"`
 		ContractAddress   common.Address `json:"contractAddress"`
 		GasUsed           hexutil.Uint64 `json:"gasUsed" gencodec:"required"`
+		MetaGasUsed       hexutil.Uint64 `json:"metaGasUsed" gencodec:"required"`
 	}
 	var enc Receipt
 	enc.PostState = r.PostState
@@ -29,12 +32,15 @@ func (r Receipt) MarshalJSON() ([]byte, error) {
 	enc.CumulativeGasUsed = hexutil.Uint64(r.CumulativeGasUsed)
 	enc.Bloom = r.Bloom
 	enc.Logs = r.Logs
+	enc.MetaLogs = r.MetaLogs
 	enc.TxHash = r.TxHash
 	enc.ContractAddress = r.ContractAddress
 	enc.GasUsed = hexutil.Uint64(r.GasUsed)
+	enc.MetaGasUsed = hexutil.Uint64(r.MetaGasUsed)
 	return json.Marshal(&enc)
 }
 
+// UnmarshalJSON unmarshals from JSON.
 func (r *Receipt) UnmarshalJSON(input []byte) error {
 	type Receipt struct {
 		PostState         *hexutil.Bytes  `json:"root"`
@@ -42,9 +48,11 @@ func (r *Receipt) UnmarshalJSON(input []byte) error {
 		CumulativeGasUsed *hexutil.Uint64 `json:"cumulativeGasUsed" gencodec:"required"`
 		Bloom             *Bloom          `json:"logsBloom"         gencodec:"required"`
 		Logs              []*Log          `json:"logs"              gencodec:"required"`
+		MetaLogs          []*MetaLog      `json:"metaLogs"          gencodec:"required"`
 		TxHash            *common.Hash    `json:"transactionHash" gencodec:"required"`
 		ContractAddress   *common.Address `json:"contractAddress"`
 		GasUsed           *hexutil.Uint64 `json:"gasUsed" gencodec:"required"`
+		MetaGasUsed       *hexutil.Uint64 `json:"metaGasUsed" gencodec:"required"`
 	}
 	var dec Receipt
 	if err := json.Unmarshal(input, &dec); err != nil {
@@ -68,6 +76,10 @@ func (r *Receipt) UnmarshalJSON(input []byte) error {
 		return errors.New("missing required field 'logs' for Receipt")
 	}
 	r.Logs = dec.Logs
+	if dec.MetaLogs == nil {
+		return errors.New("missing required field 'metaLogs' for Receipt")
+	}
+	r.MetaLogs = dec.MetaLogs
 	if dec.TxHash == nil {
 		return errors.New("missing required field 'transactionHash' for Receipt")
 	}
@@ -79,5 +91,9 @@ func (r *Receipt) UnmarshalJSON(input []byte) error {
 		return errors.New("missing required field 'gasUsed' for Receipt")
 	}
 	r.GasUsed = uint64(*dec.GasUsed)
+	if dec.MetaGasUsed == nil {
+		return errors.New("missing required field 'metaGasUsed' for Receipt")
+	}
+	r.MetaGasUsed = uint64(*dec.MetaGasUsed)
 	return nil
 }
```
### core/types/gen_tx_json.go
* generated file
```diff
diff --git a/core/types/gen_tx_json.go b/core/types/gen_tx_json.go
index c27da67..ef6ac7f 100644
--- a/core/types/gen_tx_json.go
+++ b/core/types/gen_tx_json.go
@@ -13,18 +13,22 @@ import (
 
 var _ = (*txdataMarshaling)(nil)
 
+// MarshalJSON marshals as JSON.
 func (t txdata) MarshalJSON() ([]byte, error) {
 	type txdata struct {
-		AccountNonce hexutil.Uint64  `json:"nonce"    gencodec:"required"`
-		Price        *hexutil.Big    `json:"gasPrice" gencodec:"required"`
-		GasLimit     hexutil.Uint64  `json:"gas"      gencodec:"required"`
-		Recipient    *common.Address `json:"to"       rlp:"nil"`
-		Amount       *hexutil.Big    `json:"value"    gencodec:"required"`
-		Payload      hexutil.Bytes   `json:"input"    gencodec:"required"`
-		V            *hexutil.Big    `json:"v" gencodec:"required"`
-		R            *hexutil.Big    `json:"r" gencodec:"required"`
-		S            *hexutil.Big    `json:"s" gencodec:"required"`
-		Hash         *common.Hash    `json:"hash" rlp:"-"`
+		AccountNonce  hexutil.Uint64  `json:"nonce"         gencodec:"required"`
+		Price         *hexutil.Big    `json:"gasPrice"      gencodec:"required"`
+		GasLimit      hexutil.Uint64  `json:"gas"           gencodec:"required"`
+		Recipient     *common.Address `json:"to"            rlp:"nil"`
+		Amount        *hexutil.Big    `json:"value"         gencodec:"required"`
+		Payload       hexutil.Bytes   `json:"input"         gencodec:"required"`
+		Metadata      hexutil.Bytes   `json:"metadata"      gencodec:"required"`
+		MetadataLimit *hexutil.Big    `json:"metadataLimit" gencodec:"required"`
+		IsOld         hexutil.Uint    `json:"isOld" gencodec:"required"`
+		V             *hexutil.Big    `json:"v" gencodec:"required"`
+		R             *hexutil.Big    `json:"r" gencodec:"required"`
+		S             *hexutil.Big    `json:"s" gencodec:"required"`
+		Hash          *common.Hash    `json:"hash" rlp:"-"`
 	}
 	var enc txdata
 	enc.AccountNonce = hexutil.Uint64(t.AccountNonce)
@@ -33,6 +37,9 @@ func (t txdata) MarshalJSON() ([]byte, error) {
 	enc.Recipient = t.Recipient
 	enc.Amount = (*hexutil.Big)(t.Amount)
 	enc.Payload = t.Payload
+	enc.Metadata = t.Metadata
+	enc.MetadataLimit = (*hexutil.Big)(t.MetadataLimit)
+	enc.IsOld = hexutil.Uint(t.IsOld)
 	enc.V = (*hexutil.Big)(t.V)
 	enc.R = (*hexutil.Big)(t.R)
 	enc.S = (*hexutil.Big)(t.S)
@@ -40,18 +47,22 @@ func (t txdata) MarshalJSON() ([]byte, error) {
 	return json.Marshal(&enc)
 }
 
+// UnmarshalJSON unmarshals from JSON.
 func (t *txdata) UnmarshalJSON(input []byte) error {
 	type txdata struct {
-		AccountNonce *hexutil.Uint64 `json:"nonce"    gencodec:"required"`
-		Price        *hexutil.Big    `json:"gasPrice" gencodec:"required"`
-		GasLimit     *hexutil.Uint64 `json:"gas"      gencodec:"required"`
-		Recipient    *common.Address `json:"to"       rlp:"nil"`
-		Amount       *hexutil.Big    `json:"value"    gencodec:"required"`
-		Payload      *hexutil.Bytes  `json:"input"    gencodec:"required"`
-		V            *hexutil.Big    `json:"v" gencodec:"required"`
-		R            *hexutil.Big    `json:"r" gencodec:"required"`
-		S            *hexutil.Big    `json:"s" gencodec:"required"`
-		Hash         *common.Hash    `json:"hash" rlp:"-"`
+		AccountNonce  *hexutil.Uint64 `json:"nonce"         gencodec:"required"`
+		Price         *hexutil.Big    `json:"gasPrice"      gencodec:"required"`
+		GasLimit      *hexutil.Uint64 `json:"gas"           gencodec:"required"`
+		Recipient     *common.Address `json:"to"            rlp:"nil"`
+		Amount        *hexutil.Big    `json:"value"         gencodec:"required"`
+		Payload       *hexutil.Bytes  `json:"input"         gencodec:"required"`
+		Metadata      *hexutil.Bytes  `json:"metadata"      gencodec:"required"`
+		MetadataLimit *hexutil.Big    `json:"metadataLimit" gencodec:"required"`
+		IsOld         *hexutil.Uint   `json:"isOld" gencodec:"required"`
+		V             *hexutil.Big    `json:"v" gencodec:"required"`
+		R             *hexutil.Big    `json:"r" gencodec:"required"`
+		S             *hexutil.Big    `json:"s" gencodec:"required"`
+		Hash          *common.Hash    `json:"hash" rlp:"-"`
 	}
 	var dec txdata
 	if err := json.Unmarshal(input, &dec); err != nil {
@@ -80,6 +91,18 @@ func (t *txdata) UnmarshalJSON(input []byte) error {
 		return errors.New("missing required field 'input' for txdata")
 	}
 	t.Payload = *dec.Payload
+	if dec.Metadata == nil {
+		return errors.New("missing required field 'metadata' for txdata")
+	}
+	t.Metadata = *dec.Metadata
+	if dec.MetadataLimit == nil {
+		return errors.New("missing required field 'metadataLimit' for txdata")
+	}
+	t.MetadataLimit = (*big.Int)(dec.MetadataLimit)
+	if dec.IsOld == nil {
+		return errors.New("missing required field 'isOld' for txdata")
+	}
+	t.IsOld = uint(*dec.IsOld)
 	if dec.V == nil {
 		return errors.New("missing required field 'v' for txdata")
 	}
```
### core/types/metalogs.go
* Type describing the structure of unpacked metadata
```diff
diff --git a/core/types/metalogs.go b/core/types/metalogs.go
new file mode 100644
index 0000000..9796382
--- /dev/null
+++ b/core/types/metalogs.go
@@ -0,0 +1,44 @@
+// Copyright 2018 ... iolite.TODO
+
+package types
+
+import (
+	"io"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+//go:generate gencodec -type MetaLog -field-override metalogMarshaling -out gen_metalog_json.go
+
+// Metadata
+type MetaLogs struct {
+	logs []*MetaLog
+}
+
+type MetaLog struct {
+	Recipient *common.Address `json:"to"    gencodec:"required"`
+	Amount    *big.Int        `json:"value" gencodec:"required"`
+}
+
+type metalogMarshaling struct {
+	Amount *hexutil.Big
+}
+
+// EncodeRLP implements rlp.Encoder
+func (meta *MetaLogs) EncodeRLP(w io.Writer) error {
+	return rlp.Encode(w, &meta.logs)
+}
+
+// DecodeRLP implements rlp.Decoder
+func (meta *MetaLogs) DecodeRLP(s *rlp.Stream) error {
+	return s.Decode(&meta.logs)
+}
+
+func (meta *MetaLogs) Logs() []*MetaLog { return meta.logs }
+
+func (meta *MetaLogs) Push(recipient common.Address, amount *big.Int) {
+	meta.logs = append(meta.logs, &MetaLog{&recipient, amount})
+}
```
### core/types/new_iolite_transaction.go
* Intermediate type containing metadata fields specific for the **Iolite**
```diff
diff --git a/core/types/new_iolite_transaction.go b/core/types/new_iolite_transaction.go
new file mode 100644
index 0000000..7d3ff36
--- /dev/null
+++ b/core/types/new_iolite_transaction.go
@@ -0,0 +1,97 @@
+// Copyright 2018 ... iolite.TODO
+
+package types
+
+import (
+	"io"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+// IoliteTransaction is an extra type, necessary for maintaining iolite transactions.
+type NewIoliteTransaction struct {
+	data newtxdata
+}
+
+type newtxdata struct {
+	AccountNonce  uint64          `json:"nonce"         gencodec:"required"`
+	Price         *big.Int        `json:"gasPrice"      gencodec:"required"`
+	GasLimit      uint64          `json:"gas"           gencodec:"required"`
+	Recipient     *common.Address `json:"to"            rlp:"nil"` // nil means contract creation
+	Amount        *big.Int        `json:"value"         gencodec:"required"`
+	Payload       []byte          `json:"input"         gencodec:"required"`
+	Metadata      []byte          `json:"metadata"      gencodec:"required"`
+	MetadataLimit *big.Int        `json:"metadataLimit" gencodec:"required"`
+
+	// Signature values
+	V *big.Int `json:"v" gencodec:"required"`
+	R *big.Int `json:"r" gencodec:"required"`
+	S *big.Int `json:"s" gencodec:"required"`
+}
+
+// EncodeRLP implements rlp.Encoder
+func (tx *NewIoliteTransaction) EncodeRLP(w io.Writer) error {
+	return rlp.Encode(w, &tx.data)
+}
+
+// DecodeRLP implements rlp.Decoder
+func (tx *NewIoliteTransaction) DecodeRLP(s *rlp.Stream) error {
+	return s.Decode(&tx.data)
+}
+
+// AsTransaction returns the OldTransaction as a Transaction.
+func (tx *NewIoliteTransaction) AsTransaction() *Transaction {
+	d := txdata{
+		AccountNonce:  tx.data.AccountNonce,
+		Recipient:     tx.data.Recipient,
+		Payload:       tx.data.Payload,
+		Amount:        tx.data.Amount,
+		GasLimit:      tx.data.GasLimit,
+		Price:         tx.data.Price,
+		Metadata:      tx.data.Metadata,
+		MetadataLimit: tx.data.MetadataLimit,
+		IsOld:         0,
+		V:             tx.data.V,
+		R:             tx.data.R,
+		S:             tx.data.S,
+	}
+
+	return &Transaction{data: d}
+}
+
+func CreateNewTransaction(nonce uint64, to common.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *NewIoliteTransaction {
+	return createNewTransaction(nonce, &to, amount, gasLimit, gasPrice, data)
+}
+
+func CreateNewContractCreation(nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *NewIoliteTransaction {
+	return createNewTransaction(nonce, nil, amount, gasLimit, gasPrice, data)
+}
+
+func createNewTransaction(nonce uint64, to *common.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *NewIoliteTransaction {
+	if len(data) > 0 {
+		data = common.CopyBytes(data)
+	}
+	d := newtxdata{
+		AccountNonce:  nonce,
+		Recipient:     to,
+		Payload:       data,
+		Amount:        new(big.Int),
+		GasLimit:      gasLimit,
+		Price:         new(big.Int),
+		Metadata:      nil,
+		MetadataLimit: new(big.Int),
+		V:             new(big.Int),
+		R:             new(big.Int),
+		S:             new(big.Int),
+	}
+	if amount != nil {
+		d.Amount.Set(amount)
+	}
+	if gasPrice != nil {
+		d.Price.Set(gasPrice)
+	}
+
+	return &NewIoliteTransaction{data: d}
+}
```
### core/types/old_transaction.go
* Saved structure of the Ethereum transaction
* Intermediate type that is used for backward compatibility
```diff
diff --git a/core/types/old_transaction.go b/core/types/old_transaction.go
new file mode 100644
index 0000000..b85206f
--- /dev/null
+++ b/core/types/old_transaction.go
@@ -0,0 +1,93 @@
+// Copyright 2018 ... iolite.TODO
+
+package types
+
+import (
+	"io"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+// OldTransaction is an extra type, necessary for maintaining pure ethereum transactions.
+type OldTransaction struct {
+	data oldtxdata
+}
+
+type oldtxdata struct {
+	AccountNonce uint64          `json:"nonce"    gencodec:"required"`
+	Price        *big.Int        `json:"gasPrice" gencodec:"required"`
+	GasLimit     uint64          `json:"gas"      gencodec:"required"`
+	Recipient    *common.Address `json:"to"       rlp:"nil"` // nil means contract creation
+	Amount       *big.Int        `json:"value"    gencodec:"required"`
+	Payload      []byte          `json:"input"    gencodec:"required"`
+
+	// Signature values
+	V *big.Int `json:"v" gencodec:"required"`
+	R *big.Int `json:"r" gencodec:"required"`
+	S *big.Int `json:"s" gencodec:"required"`
+}
+
+// EncodeRLP implements rlp.Encoder
+func (tx *OldTransaction) EncodeRLP(w io.Writer) error {
+	return rlp.Encode(w, &tx.data)
+}
+
+// DecodeRLP implements rlp.Decoder
+func (tx *OldTransaction) DecodeRLP(s *rlp.Stream) error {
+	return s.Decode(&tx.data)
+}
+
+// AsTransaction returns the OldTransaction as a Transaction.
+func (tx *OldTransaction) AsTransaction() *Transaction {
+	d := txdata{
+		AccountNonce:  tx.data.AccountNonce,
+		Recipient:     tx.data.Recipient,
+		Payload:       tx.data.Payload,
+		Amount:        tx.data.Amount,
+		GasLimit:      tx.data.GasLimit,
+		Price:         tx.data.Price,
+		Metadata:      nil,
+		MetadataLimit: new(big.Int),
+		IsOld:         1,
+		V:             tx.data.V,
+		R:             tx.data.R,
+		S:             tx.data.S,
+	}
+
+	return &Transaction{data: d}
+}
+
+func CreateOldTransaction(nonce uint64, to common.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *OldTransaction {
+	return createOldTransaction(nonce, &to, amount, gasLimit, gasPrice, data)
+}
+
+func CreateOldContractCreation(nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *OldTransaction {
+	return createOldTransaction(nonce, nil, amount, gasLimit, gasPrice, data)
+}
+
+func createOldTransaction(nonce uint64, to *common.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *OldTransaction {
+	if len(data) > 0 {
+		data = common.CopyBytes(data)
+	}
+	d := oldtxdata{
+		AccountNonce: nonce,
+		Recipient:    to,
+		Payload:      data,
+		Amount:       new(big.Int),
+		GasLimit:     gasLimit,
+		Price:        new(big.Int),
+		V:            new(big.Int),
+		R:            new(big.Int),
+		S:            new(big.Int),
+	}
+	if amount != nil {
+		d.Amount.Set(amount)
+	}
+	if gasPrice != nil {
+		d.Price.Set(gasPrice)
+	}
+
+	return &OldTransaction{data: d}
+}
```
### core/types/old_transaction_test.go
* back compatibility test
```diff
diff --git a/core/types/old_transaction_test.go b/core/types/old_transaction_test.go
new file mode 100644
index 0000000..61edc8b
--- /dev/null
+++ b/core/types/old_transaction_test.go
@@ -0,0 +1,43 @@
+// Copyright 2018 ... iolite.TODO
+package types
+
+import (
+	"bytes"
+	"testing"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/rlp"
+)
+
+func TestNewTransaction(t *testing.T) {
+	var tx Transaction
+	err := rlp.Decode(bytes.NewReader(common.Hex2Bytes("f8a08183850430e23400833d090094c01bab898cc6aa51273a7a31bae1a32e5cbc517b8502540be40080b3f2d894c01bab898cc6aa51273a7a31bae1a32e5cbc517b822b67d894f0476fab07ee687f7f1feeb41703b7da737802628256ce801ca00e9f4ee0174f50425613f3707b9d7e5c439b295323a0d1da614e4ede558463d1a0258dfe621c94691f7fff3d0db08ba7eeef84bfb3e407cf53da40e44a4e72bfe4")), &tx)
+	if err != nil {
+		t.Error(err)
+		t.FailNow()
+	}
+
+	metadata := hexutil.Bytes(tx.Metadata()).String()
+	should := "0xf2d894c01bab898cc6aa51273a7a31bae1a32e5cbc517b822b67d894f0476fab07ee687f7f1feeb41703b7da737802628256ce"
+	if metadata != should {
+		t.Errorf("Metadata mismatch, got %s, should %s", metadata, should)
+		t.FailNow()
+	}
+}
+
+func TestOldTransaction(t *testing.T) {
+	var tx OldTransaction
+	err := rlp.Decode(bytes.NewReader(common.Hex2Bytes("f909833a84ee6b2800833d09008080b9092e606060405260408051908101604052600281527f4c310000000000000000000000000000000000000000000000000000000000006020820152600690805161004b92916020019061011c565b50341561005757600080fd5b633b9aca006000818155600160a060020a03301681526001602052604090819020919091558051908101604052600a81527f4c69676874546f6b656e00000000000000000000000000000000000000000000602082015260039080516100c192916020019061011c565b506004805460ff1916600317905560408051908101604052600281527f4c540000000000000000000000000000000000000000000000000000000000006020820152600590805161011692916020019061011c565b506101b7565b828054600181600116156101000203166002900490600052602060002090601f016020900481019282601f1061015d57805160ff191683800117855561018a565b8280016001018555821561018a579182015b8281111561018a57825182559160200191906001019061016f565b5061019692915061019a565b5090565b6101b491905b8082111561019657600081556001016101a0565b90565b610768806101c66000396000f3006060604052600436106100ae5763ffffffff7c010000000000000000000000000000000000000000000000000000000060003504166306fdde0381146100b3578063095ea7b31461013d57806318160ddd1461017357806323b872dd14610198578063313ce567146101c05780634e71d92d146101e957806354fd4d50146101fc57806370a082311461020f57806395d89b411461022e578063a9059cbb14610241578063dd62ed3e14610263575b600080fd5b34156100be57600080fd5b6100c6610288565b60405160208082528190810183818151815260200191508051906020019080838360005b838110156101025780820151838201526020016100ea565b50505050905090810190601f16801561012f5780820380516001836020036101000a031916815260200191505b509250505060405180910390f35b341561014857600080fd5b61015f600160a060020a0360043516602435610326565b604051901515815260200160405180910390f35b341561017e57600080fd5b610186610392565b60405190815260200160405180910390f35b34156101a357600080fd5b61015f600160a060020a0360043581169060243516604435610398565b34156101cb57600080fd5b6101d36104a6565b60405160ff909116815260200160405180910390f35b34156101f457600080fd5b61015f6104af565b341561020757600080fd5b6100c6610565565b341561021a57600080fd5b610186600160a060020a03600435166105d0565b341561023957600080fd5b6100c66105eb565b341561024c57600080fd5b61015f600160a060020a0360043516602435610656565b341561026e57600080fd5b610186600160a060020a0360043581169060243516610711565b60038054600181600116156101000203166002900480601f01602080910402602001604051908101604052809291908181526020018280546001816001161561010002031660029004801561031e5780601f106102f35761010080835404028352916020019161031e565b820191906000526020600020905b81548152906001019060200180831161030157829003601f168201915b505050505081565b600160a060020a03338116600081815260026020908152604080832094871680845294909152808220859055909291907f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b9259085905190815260200160405180910390a350600192915050565b60005481565b600160a060020a0383166000908152600160205260408120548290108015906103e85750600160a060020a0380851660009081526002602090815260408083203390941683529290522054829010155b801561040d5750600160a060020a038316600090815260016020526040902054828101115b151561041857600080fd5b600160a060020a03808416600081815260016020908152604080832080548801905588851680845281842080548990039055600283528184203390961684529490915290819020805486900390559091907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9085905190815260200160405180910390a35060019392505050565b60045460ff1681565b600160a060020a0330811660009081526001602052604080822054339093168252812054909182916103e890910490106104e857600080fd5b50600160a060020a033081166000818152600160205260408082208054339095168084528284208054612710909704968701905592849052805485900390559091907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9084905190815260200160405180910390a3600191505090565b60068054600181600116156101000203166002900480601f01602080910402602001604051908101604052809291908181526020018280546001816001161561010002031660029004801561031e5780601f106102f35761010080835404028352916020019161031e565b600160a060020a031660009081526001602052604090205490565b60058054600181600116156101000203166002900480601f01602080910402602001604051908101604052809291908181526020018280546001816001161561010002031660029004801561031e5780601f106102f35761010080835404028352916020019161031e565b600160a060020a0333166000908152600160205260408120548290108015906106985750600160a060020a038316600090815260016020526040902054828101115b15156106a357600080fd5b600160a060020a033381166000818152600160205260408082208054879003905592861680825290839020805486019055917fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9085905190815260200160405180910390a350600192915050565b600160a060020a039182166000908152600260209081526040808320939094168252919091522054905600a165627a7a72305820703e40f0b83a73193a988a76f347cba2a882ca820b0b7af5fe7d12b3eae553ca00298325ab46a08fc1a0da7f8b748c1b563781d6f98c9a08dc59ef8b9db0a3d8d2c7adb6727c82a06170df4b6f8a6be1bf3c879f8082ade0c8bd640cbcced677a4be1153253dac35")), &tx)
+	if err != nil {
+		t.Error(err)
+		t.FailNow()
+	}
+
+	metadata := hexutil.Bytes(tx.AsTransaction().Metadata()).String()
+	should := "0x"
+	if metadata != should {
+		t.Errorf("Metadata mismatch, got %s, should %s", metadata, should)
+		t.FailNow()
+	}
+}
```
### core/types/receipt.go
* **metaLogs** field added
* **metaGasUsed** field added
```diff
diff --git a/core/types/receipt.go b/core/types/receipt.go
index 613f03d..5a625b0 100644
--- a/core/types/receipt.go
+++ b/core/types/receipt.go
@@ -20,10 +20,12 @@ import (
 	"bytes"
 	"fmt"
 	"io"
+	"math/big"
 	"unsafe"
 
 	"github.com/ethereum/go-ethereum/common"
 	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/log"
 	"github.com/ethereum/go-ethereum/rlp"
 )
 
@@ -45,16 +47,18 @@ const (
 // Receipt represents the results of a transaction.
 type Receipt struct {
 	// Consensus fields
-	PostState         []byte `json:"root"`
-	Status            uint   `json:"status"`
-	CumulativeGasUsed uint64 `json:"cumulativeGasUsed" gencodec:"required"`
-	Bloom             Bloom  `json:"logsBloom"         gencodec:"required"`
-	Logs              []*Log `json:"logs"              gencodec:"required"`
+	PostState         []byte     `json:"root"`
+	Status            uint       `json:"status"`
+	CumulativeGasUsed uint64     `json:"cumulativeGasUsed" gencodec:"required"`
+	Bloom             Bloom      `json:"logsBloom"         gencodec:"required"`
+	Logs              []*Log     `json:"logs"              gencodec:"required"`
+	MetaLogs          []*MetaLog `json:"metaLogs"          gencodec:"required"`
 
 	// Implementation fields (don't reorder!)
 	TxHash          common.Hash    `json:"transactionHash" gencodec:"required"`
 	ContractAddress common.Address `json:"contractAddress"`
 	GasUsed         uint64         `json:"gasUsed" gencodec:"required"`
+	MetaGasUsed     uint64         `json:"metaGasUsed" gencodec:"required"`
 }
 
 type receiptMarshaling struct {
@@ -62,6 +66,7 @@ type receiptMarshaling struct {
 	Status            hexutil.Uint
 	CumulativeGasUsed hexutil.Uint64
 	GasUsed           hexutil.Uint64
+	MetaGasUsed       hexutil.Uint64
 }
 
 // receiptRLP is the consensus encoding of a receipt.
@@ -70,6 +75,7 @@ type receiptRLP struct {
 	CumulativeGasUsed uint64
 	Bloom             Bloom
 	Logs              []*Log
+	MetaLogs          []*MetaLog
 }
 
 type receiptStorageRLP struct {
@@ -79,7 +85,9 @@ type receiptStorageRLP struct {
 	TxHash            common.Hash
 	ContractAddress   common.Address
 	Logs              []*LogForStorage
+	MetaLogs          []*MetaLog
 	GasUsed           uint64
+	MetaGasUsed       uint64
 }
 
 // NewReceipt creates a barebone transaction receipt, copying the init fields.
@@ -96,7 +104,7 @@ func NewReceipt(root []byte, failed bool, cumulativeGasUsed uint64) *Receipt {
 // EncodeRLP implements rlp.Encoder, and flattens the consensus fields of a receipt
 // into an RLP stream. If no post state is present, byzantium fork is assumed.
 func (r *Receipt) EncodeRLP(w io.Writer) error {
-	return rlp.Encode(w, &receiptRLP{r.statusEncoding(), r.CumulativeGasUsed, r.Bloom, r.Logs})
+	return rlp.Encode(w, &receiptRLP{r.statusEncoding(), r.CumulativeGasUsed, r.Bloom, r.Logs, r.MetaLogs})
 }
 
 // DecodeRLP implements rlp.Decoder, and loads the consensus fields of a receipt
@@ -110,6 +118,7 @@ func (r *Receipt) DecodeRLP(s *rlp.Stream) error {
 		return err
 	}
 	r.CumulativeGasUsed, r.Bloom, r.Logs = dec.CumulativeGasUsed, dec.Bloom, dec.Logs
+	r.MetaLogs = dec.MetaLogs
 	return nil
 }
 
@@ -146,6 +155,15 @@ func (r *Receipt) Size() common.StorageSize {
 	for _, log := range r.Logs {
 		size += common.StorageSize(len(log.Topics)*common.HashLength + len(log.Data))
 	}
+
+	size += common.StorageSize(len(r.MetaLogs)) * common.StorageSize(unsafe.Sizeof(MetaLog{}))
+	for _, metalog := range r.MetaLogs {
+		size += common.StorageSize(common.AddressLength)
+		size += common.StorageSize(len(metalog.Amount.Bits())) * common.StorageSize(unsafe.Sizeof(big.Word(0)))
+	}
+
+	//iolite.TODO: Test during synchronization of the blockchain
+	log.Iolite("Receipt", "Size", size)
 	return size
 }
 
@@ -163,7 +181,9 @@ func (r *ReceiptForStorage) EncodeRLP(w io.Writer) error {
 		TxHash:            r.TxHash,
 		ContractAddress:   r.ContractAddress,
 		Logs:              make([]*LogForStorage, len(r.Logs)),
+		MetaLogs:          r.MetaLogs,
 		GasUsed:           r.GasUsed,
+		MetaGasUsed:       r.MetaGasUsed,
 	}
 	for i, log := range r.Logs {
 		enc.Logs[i] = (*LogForStorage)(log)
@@ -187,6 +207,8 @@ func (r *ReceiptForStorage) DecodeRLP(s *rlp.Stream) error {
 	for i, log := range dec.Logs {
 		r.Logs[i] = (*Log)(log)
 	}
+	r.MetaLogs = dec.MetaLogs
+	r.MetaGasUsed = dec.MetaGasUsed
 	// Assign the implementation fields
 	r.TxHash, r.ContractAddress, r.GasUsed = dec.TxHash, dec.ContractAddress, dec.GasUsed
 	return nil
```
```diff
diff --git a/core/types/transaction.go b/core/types/transaction.go
index 70d757c..5340be7 100644
--- a/core/types/transaction.go
+++ b/core/types/transaction.go
@@ -54,12 +54,16 @@ type Transaction struct {
 }
 
 type txdata struct {
-	AccountNonce uint64          `json:"nonce"    gencodec:"required"`
-	Price        *big.Int        `json:"gasPrice" gencodec:"required"`
-	GasLimit     uint64          `json:"gas"      gencodec:"required"`
-	Recipient    *common.Address `json:"to"       rlp:"nil"` // nil means contract creation
-	Amount       *big.Int        `json:"value"    gencodec:"required"`
-	Payload      []byte          `json:"input"    gencodec:"required"`
+	AccountNonce  uint64          `json:"nonce"         gencodec:"required"`
+	Price         *big.Int        `json:"gasPrice"      gencodec:"required"`
+	GasLimit      uint64          `json:"gas"           gencodec:"required"`
+	Recipient     *common.Address `json:"to"            rlp:"nil"` // nil means contract creation
+	Amount        *big.Int        `json:"value"         gencodec:"required"`
+	Payload       []byte          `json:"input"         gencodec:"required"`
+	Metadata      []byte          `json:"metadata"      gencodec:"required"`
+	MetadataLimit *big.Int        `json:"metadataLimit" gencodec:"required"`
+
+	IsOld uint `json:"isOld" gencodec:"required"`
 
 	// Signature values
 	V *big.Int `json:"v" gencodec:"required"`
@@ -71,14 +75,17 @@ type txdata struct {
 }
 
 type txdataMarshaling struct {
-	AccountNonce hexutil.Uint64
-	Price        *hexutil.Big
-	GasLimit     hexutil.Uint64
-	Amount       *hexutil.Big
-	Payload      hexutil.Bytes
-	V            *hexutil.Big
-	R            *hexutil.Big
-	S            *hexutil.Big
+	AccountNonce  hexutil.Uint64
+	Price         *hexutil.Big
+	GasLimit      hexutil.Uint64
+	Amount        *hexutil.Big
+	Payload       hexutil.Bytes
+	Metadata      hexutil.Bytes
+	MetadataLimit *hexutil.Big
+	IsOld         hexutil.Uint
+	V             *hexutil.Big
+	R             *hexutil.Big
+	S             *hexutil.Big
 }
 
 func NewTransaction(nonce uint64, to common.Address, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte) *Transaction {
@@ -94,15 +101,18 @@ func newTransaction(nonce uint64, to *common.Address, amount *big.Int, gasLimit
 		data = common.CopyBytes(data)
 	}
 	d := txdata{
-		AccountNonce: nonce,
-		Recipient:    to,
-		Payload:      data,
-		Amount:       new(big.Int),
-		GasLimit:     gasLimit,
-		Price:        new(big.Int),
-		V:            new(big.Int),
-		R:            new(big.Int),
-		S:            new(big.Int),
+		AccountNonce:  nonce,
+		Recipient:     to,
+		Payload:       data,
+		Amount:        new(big.Int),
+		GasLimit:      gasLimit,
+		Price:         new(big.Int),
+		Metadata:      nil,
+		MetadataLimit: new(big.Int),
+		IsOld:         0,
+		V:             new(big.Int),
+		R:             new(big.Int),
+		S:             new(big.Int),
 	}
 	if amount != nil {
 		d.Amount.Set(amount)
@@ -177,12 +187,15 @@ func (tx *Transaction) UnmarshalJSON(input []byte) error {
 	return nil
 }
 
-func (tx *Transaction) Data() []byte       { return common.CopyBytes(tx.data.Payload) }
-func (tx *Transaction) Gas() uint64        { return tx.data.GasLimit }
-func (tx *Transaction) GasPrice() *big.Int { return new(big.Int).Set(tx.data.Price) }
-func (tx *Transaction) Value() *big.Int    { return new(big.Int).Set(tx.data.Amount) }
-func (tx *Transaction) Nonce() uint64      { return tx.data.AccountNonce }
-func (tx *Transaction) CheckNonce() bool   { return true }
+func (tx *Transaction) Data() []byte            { return common.CopyBytes(tx.data.Payload) }
+func (tx *Transaction) Metadata() []byte        { return common.CopyBytes(tx.data.Metadata) }
+func (tx *Transaction) MetadataLimit() *big.Int { return new(big.Int).Set(tx.data.MetadataLimit) }
+func (tx *Transaction) Gas() uint64             { return tx.data.GasLimit }
+func (tx *Transaction) GasPrice() *big.Int      { return new(big.Int).Set(tx.data.Price) }
+func (tx *Transaction) Value() *big.Int         { return new(big.Int).Set(tx.data.Amount) }
+func (tx *Transaction) Nonce() uint64           { return tx.data.AccountNonce }
+func (tx *Transaction) CheckNonce() bool        { return true }
+func (tx *Transaction) IsOld() bool             { return tx.data.IsOld != 0 }
 
 // To returns the recipient address of the transaction.
 // It returns nil if the transaction is a contract creation.
@@ -200,7 +213,12 @@ func (tx *Transaction) Hash() common.Hash {
 	if hash := tx.hash.Load(); hash != nil {
 		return hash.(common.Hash)
 	}
-	v := rlpHash(tx)
+	var v common.Hash
+	if tx.IsOld() {
+		v = rlpHash(tx.AsOldTransaction())
+	} else {
+		v = rlpHash(tx.AsNewIoliteTransaction())
+	}
 	tx.hash.Store(v)
 	return v
 }
@@ -224,13 +242,15 @@ func (tx *Transaction) Size() common.StorageSize {
 // XXX Rename message to something less arbitrary?
 func (tx *Transaction) AsMessage(s Signer) (Message, error) {
 	msg := Message{
-		nonce:      tx.data.AccountNonce,
-		gasLimit:   tx.data.GasLimit,
-		gasPrice:   new(big.Int).Set(tx.data.Price),
-		to:         tx.data.Recipient,
-		amount:     tx.data.Amount,
-		data:       tx.data.Payload,
-		checkNonce: true,
+		nonce:         tx.data.AccountNonce,
+		gasLimit:      tx.data.GasLimit,
+		gasPrice:      new(big.Int).Set(tx.data.Price),
+		to:            tx.data.Recipient,
+		amount:        tx.data.Amount,
+		data:          tx.data.Payload,
+		metadata:      tx.data.Metadata,
+		metadataLimit: tx.data.MetadataLimit,
+		checkNonce:    true,
 	}
 
 	var err error
@@ -238,6 +258,40 @@ func (tx *Transaction) AsMessage(s Signer) (Message, error) {
 	return msg, err
 }
 
+func (tx *Transaction) AsOldTransaction() *OldTransaction {
+	d := oldtxdata{
+		AccountNonce: tx.data.AccountNonce,
+		Recipient:    tx.data.Recipient,
+		Payload:      tx.data.Payload,
+		Amount:       tx.data.Amount,
+		GasLimit:     tx.data.GasLimit,
+		Price:        tx.data.Price,
+		V:            tx.data.V,
+		R:            tx.data.R,
+		S:            tx.data.S,
+	}
+
+	return &OldTransaction{data: d}
+}
+
+func (tx *Transaction) AsNewIoliteTransaction() *NewIoliteTransaction {
+	d := newtxdata{
+		AccountNonce:  tx.data.AccountNonce,
+		Recipient:     tx.data.Recipient,
+		Payload:       tx.data.Payload,
+		Amount:        tx.data.Amount,
+		GasLimit:      tx.data.GasLimit,
+		Price:         tx.data.Price,
+		Metadata:      tx.data.Metadata,
+		MetadataLimit: tx.data.MetadataLimit,
+		V:             tx.data.V,
+		R:             tx.data.R,
+		S:             tx.data.S,
+	}
+
+	return &NewIoliteTransaction{data: d}
+}
+
 // WithSignature returns a new transaction with the given signature.
 // This signature needs to be formatted as described in the yellow paper (v+27).
 func (tx *Transaction) WithSignature(signer Signer, sig []byte) (*Transaction, error) {
@@ -386,34 +440,44 @@ func (t *TransactionsByPriceAndNonce) Pop() {
 //
 // NOTE: In a future PR this will be removed.
 type Message struct {
-	to         *common.Address
-	from       common.Address
-	nonce      uint64
-	amount     *big.Int
-	gasLimit   uint64
-	gasPrice   *big.Int
-	data       []byte
-	checkNonce bool
-}
-
-func NewMessage(from common.Address, to *common.Address, nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte, checkNonce bool) Message {
+	to            *common.Address
+	from          common.Address
+	nonce         uint64
+	amount        *big.Int
+	gasLimit      uint64
+	gasPrice      *big.Int
+	data          []byte
+	metadata      []byte
+	metadataLimit *big.Int
+	checkNonce    bool
+}
+
+func CreateNewMessage(from common.Address, to *common.Address, nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data, metadata []byte, metadataLimit *big.Int, checkNonce bool) Message {
 	return Message{
-		from:       from,
-		to:         to,
-		nonce:      nonce,
-		amount:     amount,
-		gasLimit:   gasLimit,
-		gasPrice:   gasPrice,
-		data:       data,
-		checkNonce: checkNonce,
+		from:          from,
+		to:            to,
+		nonce:         nonce,
+		amount:        amount,
+		gasLimit:      gasLimit,
+		gasPrice:      gasPrice,
+		data:          data,
+		metadata:      metadata,
+		metadataLimit: metadataLimit,
+		checkNonce:    checkNonce,
 	}
 }
 
-func (m Message) From() common.Address { return m.from }
-func (m Message) To() *common.Address  { return m.to }
-func (m Message) GasPrice() *big.Int   { return m.gasPrice }
-func (m Message) Value() *big.Int      { return m.amount }
-func (m Message) Gas() uint64          { return m.gasLimit }
-func (m Message) Nonce() uint64        { return m.nonce }
-func (m Message) Data() []byte         { return m.data }
-func (m Message) CheckNonce() bool     { return m.checkNonce }
+func NewMessage(from common.Address, to *common.Address, nonce uint64, amount *big.Int, gasLimit uint64, gasPrice *big.Int, data []byte, checkNonce bool) Message {
+	return CreateNewMessage(from, to, nonce, amount, gasLimit, gasPrice, data, []byte{}, big.NewInt(0), checkNonce)
+}
+
+func (m Message) From() common.Address    { return m.from }
+func (m Message) To() *common.Address     { return m.to }
+func (m Message) GasPrice() *big.Int      { return m.gasPrice }
+func (m Message) Value() *big.Int         { return m.amount }
+func (m Message) Gas() uint64             { return m.gasLimit }
+func (m Message) Nonce() uint64           { return m.nonce }
+func (m Message) Data() []byte            { return m.data }
+func (m Message) Metadata() []byte        { return m.metadata }
+func (m Message) MetadataLimit() *big.Int { return m.metadataLimit }
+func (m Message) CheckNonce() bool        { return m.checkNonce }
```
### core/types/transaction_signing.go
* Support for new transactions(**Iolite**) and old(**Ethereum**) ones
```diff
diff --git a/core/types/transaction_signing.go b/core/types/transaction_signing.go
index dfc84fd..9053222 100644
--- a/core/types/transaction_signing.go
+++ b/core/types/transaction_signing.go
@@ -153,6 +153,17 @@ func (s EIP155Signer) SignatureValues(tx *Transaction, sig []byte) (R, S, V *big
 // Hash returns the hash to be signed by the sender.
 // It does not uniquely identify the transaction.
 func (s EIP155Signer) Hash(tx *Transaction) common.Hash {
+	if tx.IsOld() {
+		return rlpHash([]interface{}{
+			tx.data.AccountNonce,
+			tx.data.Price,
+			tx.data.GasLimit,
+			tx.data.Recipient,
+			tx.data.Amount,
+			tx.data.Payload,
+			s.chainId, uint(0), uint(0),
+		})
+	}
 	return rlpHash([]interface{}{
 		tx.data.AccountNonce,
 		tx.data.Price,
@@ -160,6 +171,8 @@ func (s EIP155Signer) Hash(tx *Transaction) common.Hash {
 		tx.data.Recipient,
 		tx.data.Amount,
 		tx.data.Payload,
+		tx.data.Metadata,
+		tx.data.MetadataLimit,
 		s.chainId, uint(0), uint(0),
 	})
 }
@@ -205,6 +218,16 @@ func (fs FrontierSigner) SignatureValues(tx *Transaction, sig []byte) (r, s, v *
 // Hash returns the hash to be signed by the sender.
 // It does not uniquely identify the transaction.
 func (fs FrontierSigner) Hash(tx *Transaction) common.Hash {
+	if tx.IsOld() {
+		return rlpHash([]interface{}{
+			tx.data.AccountNonce,
+			tx.data.Price,
+			tx.data.GasLimit,
+			tx.data.Recipient,
+			tx.data.Amount,
+			tx.data.Payload,
+		})
+	}
 	return rlpHash([]interface{}{
 		tx.data.AccountNonce,
 		tx.data.Price,
@@ -212,6 +235,8 @@ func (fs FrontierSigner) Hash(tx *Transaction) common.Hash {
 		tx.data.Recipient,
 		tx.data.Amount,
 		tx.data.Payload,
+		tx.data.Metadata,
+		tx.data.MetadataLimit,
 	})
 }
```
### transaction_signing_test.go
* fixed test
```diff 
diff --git a/core/types/transaction_signing_test.go b/core/types/transaction_signing_test.go
index 689fc38..2e1b492 100644
--- a/core/types/transaction_signing_test.go
+++ b/core/types/transaction_signing_test.go
@@ -94,12 +94,13 @@ func TestEIP155SigningVitalik(t *testing.T) {
 	} {
 		signer := NewEIP155Signer(big.NewInt(1))
 
-		var tx *Transaction
-		err := rlp.DecodeBytes(common.Hex2Bytes(test.txRlp), &tx)
+		var oldtx *OldTransaction
+		err := rlp.DecodeBytes(common.Hex2Bytes(test.txRlp), &oldtx)
 		if err != nil {
 			t.Errorf("%d: %v", i, err)
 			continue
 		}
+		tx := oldtx.AsTransaction()
 
 		from, err := Sender(signer, tx)
 		if err != nil {
```
### transaction_test.go
* fixed test
```diff
diff --git a/core/types/transaction_test.go b/core/types/transaction_test.go
index d1861b1..caa7e00 100644
--- a/core/types/transaction_test.go
+++ b/core/types/transaction_test.go
@@ -31,21 +31,21 @@ import (
 // The values in those tests are from the Transaction Tests
 // at github.com/ethereum/tests.
 var (
-	emptyTx = NewTransaction(
+	emptyTx = CreateOldTransaction(
 		0,
 		common.HexToAddress("095e7baea6a6c7c4c2dfeb977efac326af552d87"),
 		big.NewInt(0), 0, big.NewInt(0),
 		nil,
-	)
+	).AsTransaction()
 
-	rightvrsTx, _ = NewTransaction(
+	rightvrsTx, _ = CreateOldTransaction(
 		3,
 		common.HexToAddress("b94f5374fce5edbc8e2a8697c15331677e6ebf0b"),
 		big.NewInt(10),
 		2000,
 		big.NewInt(1),
 		common.FromHex("5544"),
-	).WithSignature(
+	).AsTransaction().WithSignature(
 		HomesteadSigner{},
 		common.Hex2Bytes("98ff921201554726367d2be8c804a7ff89ccf285ebc57dff8ae4c44b9c19ac4a8887321be575c8095f789dd4c743dfe42c1820f9231f98a962b210e3ac2452a301"),
 	)
```
### eth/api_tracer.go
* Support for the modified method signature
```diff
diff --git a/eth/api_tracer.go b/eth/api_tracer.go
index 07c4457..78e6f92 100644
--- a/eth/api_tracer.go
+++ b/eth/api_tracer.go
@@ -446,7 +446,7 @@ func (api *PrivateDebugAPI) traceBlock(ctx context.Context, block *types.Block,
 		vmctx := core.NewEVMContext(msg, block.Header(), api.eth.blockchain, nil)
 
 		vmenv := vm.NewEVM(vmctx, statedb, api.config, vm.Config{})
-		if _, _, _, err := core.ApplyMessage(vmenv, msg, new(core.GasPool).AddGas(msg.Gas())); err != nil {
+		if _, _, _, _, _, err := core.ApplyMessage(vmenv, msg, new(core.GasPool).AddGas(msg.Gas())); err != nil {
 			failed = err
 			break
 		}
@@ -588,7 +588,7 @@ func (api *PrivateDebugAPI) traceTx(ctx context.Context, message core.Message, v
 	// Run the transaction with tracing enabled.
 	vmenv := vm.NewEVM(vmctx, statedb, api.config, vm.Config{Debug: true, Tracer: tracer})
 
-	ret, gas, failed, err := core.ApplyMessage(vmenv, message, new(core.GasPool).AddGas(message.Gas()))
+	_, ret, gas, _, failed, err := core.ApplyMessage(vmenv, message, new(core.GasPool).AddGas(message.Gas()))
 	if err != nil {
 		return nil, fmt.Errorf("tracing failed: %v", err)
 	}
@@ -637,7 +637,7 @@ func (api *PrivateDebugAPI) computeTxEnv(blockHash common.Hash, txIndex int, ree
 		}
 		// Not yet the searched for transaction, execute on top of the current state
 		vmenv := vm.NewEVM(context, statedb, api.config, vm.Config{})
-		if _, _, _, err := core.ApplyMessage(vmenv, msg, new(core.GasPool).AddGas(tx.Gas())); err != nil {
+		if _, _, _, _, _, err := core.ApplyMessage(vmenv, msg, new(core.GasPool).AddGas(tx.Gas())); err != nil {
 			return nil, vm.Context{}, nil, fmt.Errorf("tx %x failed: %v", tx.Hash(), err)
 		}
 		statedb.DeleteSuicides()
```
### internal/ethapi/api.go
* Support for the modified method signature
* additional logs
* Support **metadata** fields
```diff
diff --git a/internal/ethapi/api.go b/internal/ethapi/api.go
index e2bfbaf..bfa6b31 100644
--- a/internal/ethapi/api.go
+++ b/internal/ethapi/api.go
@@ -604,12 +604,14 @@ func (s *PublicBlockChainAPI) GetStorageAt(ctx context.Context, address common.A
 
 // CallArgs represents the arguments for a call.
 type CallArgs struct {
-	From     common.Address  `json:"from"`
-	To       *common.Address `json:"to"`
-	Gas      hexutil.Uint64  `json:"gas"`
-	GasPrice hexutil.Big     `json:"gasPrice"`
-	Value    hexutil.Big     `json:"value"`
-	Data     hexutil.Bytes   `json:"data"`
+	From          common.Address  `json:"from"`
+	To            *common.Address `json:"to"`
+	Gas           hexutil.Uint64  `json:"gas"`
+	GasPrice      hexutil.Big     `json:"gasPrice"`
+	Value         hexutil.Big     `json:"value"`
+	Data          hexutil.Bytes   `json:"data"`
+	Metadata      hexutil.Bytes   `json:"metadata"`
+	MetadataLimit hexutil.Big     `json:"metadataLimit"`
 }
 
 func (s *PublicBlockChainAPI) doCall(ctx context.Context, args CallArgs, blockNr rpc.BlockNumber, vmCfg vm.Config, timeout time.Duration) ([]byte, uint64, bool, error) {
@@ -638,7 +640,7 @@ func (s *PublicBlockChainAPI) doCall(ctx context.Context, args CallArgs, blockNr
 	}
 
 	// Create new call message
-	msg := types.NewMessage(addr, args.To, 0, args.Value.ToInt(), gas, gasPrice, args.Data, false)
+	msg := types.CreateNewMessage(addr, args.To, 0, args.Value.ToInt(), gas, gasPrice, args.Data, args.Metadata, args.MetadataLimit.ToInt(), false)
 
 	// Setup context so it may be cancelled the call has completed
 	// or, in case of unmetered gas, setup a context with a timeout.
@@ -667,7 +669,7 @@ func (s *PublicBlockChainAPI) doCall(ctx context.Context, args CallArgs, blockNr
 	// Setup the gas pool (also for unmetered requests)
 	// and apply the message.
 	gp := new(core.GasPool).AddGas(math.MaxUint64)
-	res, gas, failed, err := core.ApplyMessage(evm, msg, gp)
+	_, res, gas, _, failed, err := core.ApplyMessage(evm, msg, gp)
 	if err := vmError(); err != nil {
 		return nil, 0, false, err
 	}
@@ -724,6 +726,7 @@ func (s *PublicBlockChainAPI) EstimateGas(ctx context.Context, args CallArgs) (h
 	// Reject the transaction as invalid if it still fails at the highest allowance
 	if hi == cap {
 		if !executable(hi) {
+			log.Iolite("EstimateGas", "gas required exceeds allowance or always failing transaction", args.Data)
 			return 0, fmt.Errorf("gas required exceeds allowance or always failing transaction")
 		}
 	}
@@ -858,6 +861,9 @@ type RPCTransaction struct {
 	GasPrice         *hexutil.Big    `json:"gasPrice"`
 	Hash             common.Hash     `json:"hash"`
 	Input            hexutil.Bytes   `json:"input"`
+	Metadata         hexutil.Bytes   `json:"metadata"`
+	MetadataLimit    *hexutil.Big    `json:"metadataLimit"`
+	IsOld            hexutil.Uint    `json:"isOld"`
 	Nonce            hexutil.Uint64  `json:"nonce"`
 	To               *common.Address `json:"to"`
 	TransactionIndex hexutil.Uint    `json:"transactionIndex"`
@@ -877,18 +883,26 @@ func newRPCTransaction(tx *types.Transaction, blockHash common.Hash, blockNumber
 	from, _ := types.Sender(signer, tx)
 	v, r, s := tx.RawSignatureValues()
 
+	isOld := 0
+	if tx.IsOld() {
+		isOld = 1
+	}
+
 	result := &RPCTransaction{
-		From:     from,
-		Gas:      hexutil.Uint64(tx.Gas()),
-		GasPrice: (*hexutil.Big)(tx.GasPrice()),
-		Hash:     tx.Hash(),
-		Input:    hexutil.Bytes(tx.Data()),
-		Nonce:    hexutil.Uint64(tx.Nonce()),
-		To:       tx.To(),
-		Value:    (*hexutil.Big)(tx.Value()),
-		V:        (*hexutil.Big)(v),
-		R:        (*hexutil.Big)(r),
-		S:        (*hexutil.Big)(s),
+		From:          from,
+		Gas:           hexutil.Uint64(tx.Gas()),
+		GasPrice:      (*hexutil.Big)(tx.GasPrice()),
+		Hash:          tx.Hash(),
+		Input:         hexutil.Bytes(tx.Data()),
+		Metadata:      hexutil.Bytes(tx.Metadata()),
+		MetadataLimit: (*hexutil.Big)(tx.MetadataLimit()),
+		IsOld:         hexutil.Uint(isOld),
+		Nonce:         hexutil.Uint64(tx.Nonce()),
+		To:            tx.To(),
+		Value:         (*hexutil.Big)(tx.Value()),
+		V:             (*hexutil.Big)(v),
+		R:             (*hexutil.Big)(r),
+		S:             (*hexutil.Big)(s),
 	}
 	if blockHash != (common.Hash{}) {
 		result.BlockHash = blockHash
@@ -1018,6 +1032,7 @@ func (s *PublicTransactionPoolAPI) GetTransactionByHash(ctx context.Context, has
 }
 
 // GetRawTransactionByHash returns the bytes of the transaction for the given hash.
+// iolite.TODO fix for OldTransaction and NewIoliteTransaction
 func (s *PublicTransactionPoolAPI) GetRawTransactionByHash(ctx context.Context, hash common.Hash) (hexutil.Bytes, error) {
 	var tx *types.Transaction
 
@@ -1038,6 +1053,7 @@ func (s *PublicTransactionPoolAPI) GetTransactionReceipt(ctx context.Context, ha
 	if tx == nil {
 		return nil, nil
 	}
+
 	receipts, err := s.b.GetReceipts(ctx, blockHash)
 	if err != nil {
 		return nil, err
@@ -1065,6 +1081,8 @@ func (s *PublicTransactionPoolAPI) GetTransactionReceipt(ctx context.Context, ha
 		"contractAddress":   nil,
 		"logs":              receipt.Logs,
 		"logsBloom":         receipt.Bloom,
+		"metaLogs":          receipt.MetaLogs,
+		"metaGasUsed":       receipt.MetaGasUsed,
 	}
 
 	// Assign receipt status or post state.
@@ -1076,6 +1094,9 @@ func (s *PublicTransactionPoolAPI) GetTransactionReceipt(ctx context.Context, ha
 	if receipt.Logs == nil {
 		fields["logs"] = [][]*types.Log{}
 	}
+
+	// iolite.TODO: allow metaLogs to be nil?
+
 	// If the ContractAddress is 20 0x0 bytes, assume it is not a contract creation
 	if receipt.ContractAddress != (common.Address{}) {
 		fields["contractAddress"] = receipt.ContractAddress
@@ -1112,6 +1133,7 @@ type SendTxArgs struct {
 	// newer name and should be preferred by clients.
 	Data  *hexutil.Bytes `json:"data"`
 	Input *hexutil.Bytes `json:"input"`
+	// iolite.TODO add metadata support
 }
 
 // setDefaults is a helper function that fills in default values for unspecified tx fields.
@@ -1170,6 +1192,7 @@ func (args *SendTxArgs) toTransaction() *types.Transaction {
 
 // submitTransaction is a helper function that submits tx to txPool and logs a message.
 func submitTransaction(ctx context.Context, b Backend, tx *types.Transaction) (common.Hash, error) {
+	log.Iolite("submitTransaction", "hash", tx.Hash().Hex())
 	if err := b.SendTx(ctx, tx); err != nil {
 		return common.Hash{}, err
 	}
@@ -1228,9 +1251,19 @@ func (s *PublicTransactionPoolAPI) SendTransaction(ctx context.Context, args Sen
 // The sender is responsible for signing the transaction and using the correct nonce.
 func (s *PublicTransactionPoolAPI) SendRawTransaction(ctx context.Context, encodedTx hexutil.Bytes) (common.Hash, error) {
 	tx := new(types.Transaction)
-	if err := rlp.DecodeBytes(encodedTx, tx); err != nil {
-		return common.Hash{}, err
+	oldtx := new(types.OldTransaction)
+	newtx := new(types.NewIoliteTransaction)
+
+	if err := rlp.DecodeBytes(encodedTx, oldtx); err != nil {
+		if err := rlp.DecodeBytes(encodedTx, newtx); err != nil {
+			return common.Hash{}, err
+		} else {
+			tx = newtx.AsTransaction()
+		}
+	} else {
+		tx = oldtx.AsTransaction()
 	}
+	log.Iolite("SendRawTransaction", "fullhash", tx.Hash().Hex(), "metadata", hexutil.Encode(tx.Metadata()))
 	return submitTransaction(ctx, s.b, tx)
 }
```
### les/odr_test.go
* Support for the modified method signature
```diff
diff --git a/les/odr_test.go b/les/odr_test.go
index 88e121c..fbe411c 100644
--- a/les/odr_test.go
+++ b/les/odr_test.go
@@ -135,7 +135,7 @@ func odrContractCall(ctx context.Context, db ethdb.Database, config *params.Chai
 
 				//vmenv := core.NewEnv(statedb, config, bc, msg, header, vm.Config{})
 				gp := new(core.GasPool).AddGas(math.MaxUint64)
-				ret, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
+				_, ret, _, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
 				res = append(res, ret...)
 			}
 		} else {
@@ -146,7 +146,7 @@ func odrContractCall(ctx context.Context, db ethdb.Database, config *params.Chai
 			context := core.NewEVMContext(msg, header, lc, nil)
 			vmenv := vm.NewEVM(context, state, config, vm.Config{})
 			gp := new(core.GasPool).AddGas(math.MaxUint64)
-			ret, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
+			_, ret, _, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
 			if state.Error() == nil {
 				res = append(res, ret...)
 			}
```
### light/odr_test.go
* Support for the modified method signature
```diff
diff --git a/light/odr_test.go b/light/odr_test.go
index d3f9374..7db343e 100644
--- a/light/odr_test.go
+++ b/light/odr_test.go
@@ -180,7 +180,7 @@ func odrContractCall(ctx context.Context, db ethdb.Database, bc *core.BlockChain
 		context := core.NewEVMContext(msg, header, chain, nil)
 		vmenv := vm.NewEVM(context, st, config, vm.Config{})
 		gp := new(core.GasPool).AddGas(math.MaxUint64)
-		ret, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
+		_, ret, _, _, _, _ := core.ApplyMessage(vmenv, msg, gp)
 		res = append(res, ret...)
 		if st.Error() != nil {
 			return res, st.Error()
```
### light/txpool.go
* additional logs
```diff
diff --git a/light/txpool.go b/light/txpool.go
index ca41490..baab5ec 100644
--- a/light/txpool.go
+++ b/light/txpool.go
@@ -23,6 +23,7 @@ import (
 	"time"
 
 	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
 	"github.com/ethereum/go-ethereum/core"
 	"github.com/ethereum/go-ethereum/core/state"
 	"github.com/ethereum/go-ethereum/core/types"
@@ -437,6 +438,7 @@ func (self *TxPool) Add(ctx context.Context, tx *types.Transaction) error {
 	//fmt.Println("Send", tx.Hash())
 	self.relay.Send(types.Transactions{tx})
 
+	log.Iolite("Light: Add to txpool", "data", hexutil.Encode(data))
 	self.chainDb.Put(tx.Hash().Bytes(), data)
 	return nil
 }
```
### log/format.go
* Iolite log level
```diff
diff --git a/log/format.go b/log/format.go
index 0b07abb..bd3676f 100644
--- a/log/format.go
+++ b/log/format.go
@@ -96,6 +96,8 @@ func TerminalFormat(usecolor bool) Format {
 				color = 33
 			case LvlInfo:
 				color = 32
+			case LvlIolite:
+				color = 95
 			case LvlDebug:
 				color = 36
 			case LvlTrace:
```
### log/logger.go
* Iolite log level
```diff
diff --git a/log/logger.go b/log/logger.go
index 15c83a9..1657a67 100644
--- a/log/logger.go
+++ b/log/logger.go
@@ -20,6 +20,7 @@ const (
 	LvlError
 	LvlWarn
 	LvlInfo
+	LvlIolite
 	LvlDebug
 	LvlTrace
 )
@@ -31,6 +32,8 @@ func (l Lvl) AlignedString() string {
 		return "TRACE"
 	case LvlDebug:
 		return "DEBUG"
+	case LvlIolite:
+		return "ILT  "
 	case LvlInfo:
 		return "INFO "
 	case LvlWarn:
@@ -51,6 +54,8 @@ func (l Lvl) String() string {
 		return "trce"
 	case LvlDebug:
 		return "dbug"
+	case LvlIolite:
+		return "ilt"
 	case LvlInfo:
 		return "info"
 	case LvlWarn:
@@ -72,6 +77,8 @@ func LvlFromString(lvlString string) (Lvl, error) {
 		return LvlTrace, nil
 	case "debug", "dbug":
 		return LvlDebug, nil
+	case "iolite", "ilt":
+		return LvlIolite, nil
 	case "info":
 		return LvlInfo, nil
 	case "warn":
@@ -115,6 +122,7 @@ type Logger interface {
 	// Log a message at the given level with context key/value pairs
 	Trace(msg string, ctx ...interface{})
 	Debug(msg string, ctx ...interface{})
+	Iolite(msg string, ctx ...interface{})
 	Info(msg string, ctx ...interface{})
 	Warn(msg string, ctx ...interface{})
 	Error(msg string, ctx ...interface{})
@@ -163,6 +171,10 @@ func (l *logger) Debug(msg string, ctx ...interface{}) {
 	l.write(msg, LvlDebug, ctx)
 }
 
+func (l *logger) Iolite(msg string, ctx ...interface{}) {
+	l.write(msg, LvlIolite, ctx)
+}
+
 func (l *logger) Info(msg string, ctx ...interface{}) {
 	l.write(msg, LvlInfo, ctx)
 }
```
### log/root.go
* Iolite log level
```diff
diff --git a/log/root.go b/log/root.go
index 71b8cef..1c62287 100644
--- a/log/root.go
+++ b/log/root.go
@@ -39,6 +39,11 @@ func Debug(msg string, ctx ...interface{}) {
 	root.write(msg, LvlDebug, ctx)
 }
 
+// Iolite is a convenient alias for Root().Iolite
+func Iolite(msg string, ctx ...interface{}) {
+	root.write(msg, LvlIolite, ctx)
+}
+
 // Info is a convenient alias for Root().Info
 func Info(msg string, ctx ...interface{}) {
 	root.write(msg, LvlInfo, ctx)
```
### log/syslog.go
* Iolite log level
```diff
diff --git a/log/syslog.go b/log/syslog.go
index 71a17b3..62e67c7 100644
--- a/log/syslog.go
+++ b/log/syslog.go
@@ -36,6 +36,8 @@ func sharedSyslog(fmtr Format, sysWr *syslog.Writer, err error) (Handler, error)
 			syslogFn = sysWr.Warning
 		case LvlInfo:
 			syslogFn = sysWr.Info
+		case LvlIolite:
+			syslogFn = sysWr.Info
 		case LvlDebug:
 			syslogFn = sysWr.Debug
 		case LvlTrace:
```
### node/node.go
* additional logs
```diff
diff --git a/node/node.go b/node/node.go
index b02aecf..5b1fa1f 100644
--- a/node/node.go
+++ b/node/node.go
@@ -287,7 +287,7 @@ func (n *Node) startInProc(apis []rpc.API) error {
 		if err := handler.RegisterName(api.Namespace, api.Service); err != nil {
 			return err
 		}
-		n.log.Debug("InProc registered", "service", api.Service, "namespace", api.Namespace)
+		n.log.Info("InProc registered", "service", api.Service, "namespace", api.Namespace)
 	}
 	n.inprocHandler = handler
 	return nil
```
### tests/state_test_util.go
* Support for the modified method signature
```diff
diff --git a/tests/state_test_util.go b/tests/state_test_util.go
index 3b761bd..faf62a8 100644
--- a/tests/state_test_util.go
+++ b/tests/state_test_util.go
@@ -141,7 +141,7 @@ func (t *StateTest) Run(subtest StateSubtest, vmconfig vm.Config) (*state.StateD
 	gaspool := new(core.GasPool)
 	gaspool.AddGas(block.GasLimit())
 	snapshot := statedb.Snapshot()
-	if _, _, _, err := core.ApplyMessage(evm, msg, gaspool); err != nil {
+	if _, _, _, _, _, err := core.ApplyMessage(evm, msg, gaspool); err != nil {
 		statedb.RevertToSnapshot(snapshot)
 	}
 	if logs := rlpHash(statedb.Logs()); logs != common.Hash(post.Logs) {
```
