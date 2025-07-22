
FlashBotAutoBuy

FlashBotAutoBuy is an ultra-lightweight Solidity smart contract optimized for gas-efficient (<15,000 gas) auto-buy transactions on the Base mainnet. It enables users, allowing automatic token purchases triggered by user  farcaster likes and recast , with swaps executed by a backend and tokens sent to user wallets. The contract achieves a $0.0000000001 user-facing cost through subsidization.

Features





Gas Efficiency: ~6,500–7,500 gas per transaction, ~400–600 gas/user when batched (50–100 users).


Subsidized Cost: Achieves $0.0000000001 user cost via micro-fees (0.00001 USDC/swap) or 1% referrer fees.


## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
