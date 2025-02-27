## Bonding Curve ERC20 launchpad

**This is a singleton smart contract for deploying tokens to a bonding curve similar to pumpfun but for EVM / Uniswap (foundry project)**

layout:

- **src/CurveManager.sol**: Contains the main logic for creation / swapping / bonding.
- **src/CurveQuoter.sol**: used for price quoting.
- **src/ERC20Token.sol**: Custom ERC20 that limits which smart contracts can hold the token before bond (behaves like normal after bond)

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

Some tests require env MAINNET_RPC_URL to be set (to test bond function against deployed uniswap contracts)

```shell
$ forge test
```

This is experimental software provided as is, for educational purposes. Has been tested in foundry and on testnet, please conduct your own thorough testing before using. Feel free to make a PR or open an issue if you notice any bugs.
