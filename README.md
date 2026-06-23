# Decentralized Stable Coin (DSC)

A minimal, **decentralized, overcollateralized, USD-pegged stablecoin** built with
[Foundry](https://book.getfoundry.sh/). It is a DAI-style CDP/vault system: you lock crypto
collateral (wETH / wBTC), mint a dollar-pegged token (`DSC`) against it, and your position can
be liquidated if it becomes unsafe.

> ⚠️ **Learning artifact. Testnet/local only.** No mainnet config, no real funds. The code is
> heavily commented on purpose so it can be read top-to-bottom to understand how a stablecoin
> works. Do not deploy this to mainnet or treat it as audited.

---

## What it does (the mechanism)

| Property        | Choice                                                                 |
| --------------- | ---------------------------------------------------------------------- |
| **Peg**         | Soft-pegged to **$1** (1 DSC ≈ $1 USD).                                 |
| **Collateral**  | Exogenous: **wETH** and **wBTC** (mocks on local/testnet).             |
| **Stability**   | **Overcollateralized** — always backed by *more* USD than DSC minted.  |
| **Minting**     | Algorithmic — supply is governed entirely by `DSCEngine`.              |

The rules:

1. Deposit an approved collateral token.
2. Mint DSC against it, up to a **50% loan-to-value** cap (a **200% collateralization ratio**).
3. A **Chainlink** price feed converts collateral to USD (with a stale-price guard).
4. A **health factor (HF)** measures safety: `HF ≥ 1` is safe, `HF < 1` is liquidatable.
5. Anyone can **liquidate** an unsafe position: repay its DSC debt and seize its collateral
   **plus a 10% bonus**. That bonus is the economic incentive that keeps DSC fully backed.
6. Redeem collateral by burning DSC.

### Health factor, worked example

```
Deposit:  10 wETH @ $2,000  = $20,000 collateral
Mint:     8,000 DSC                       ( = $8,000 debt )

Only 50% of collateral "counts" toward backing debt (the liquidation threshold):
  adjusted collateral = $20,000 * 50% = $10,000
  health factor       = adjusted / debt = $10,000 / $8,000 = 1.25   ✅ safe

Now ETH crashes to $1,400:
  collateral          = 10 * $1,400 = $14,000
  adjusted collateral = $14,000 * 50% = $7,000
  health factor       = $7,000 / $8,000 = 0.875  ❌ liquidatable

A liquidator repays the $8,000 DSC debt and receives:
  $8,000 / $1,400      = 5.714 wETH   (debt-equivalent collateral)
  + 10% bonus          = 0.571 wETH
  = 6.286 wETH  (≈ $8,800)  →  a ~$800 profit, paid out of the borrower's collateral.
```

---

## Architecture

```
                          mint / burn (onlyOwner)
        ┌──────────────────────────────────────────────────┐
        │                                                   ▼
   ┌─────────┐   deposit / mint / redeem / burn / liquidate ┌─────────────────────┐
   │  User   │ ───────────────────────────────────────────▶ │      DSCEngine      │
   └─────────┘                                               │  (all the logic)    │
        ▲                                                    │  - CDP accounting   │
        │ receives DSC, or seized collateral + bonus         │  - health factor    │
        └──────────────────────────────────────────────────▶│  - liquidation      │
                                                             └─────────┬───────────┘
                                                                       │ owns
                                                                       ▼
                                                          ┌─────────────────────────┐
                                                          │ DecentralizedStableCoin  │
                                                          │ (ERC20Burnable, logicless)│
                                                          └─────────────────────────┘
   DSCEngine prices collateral through:
        DSCEngine ──▶ OracleLib (stale-price guard) ──▶ Chainlink AggregatorV3 feeds
```

- **`DecentralizedStableCoin`** is intentionally "dumb": a mint/burn-gated ERC20 with no
  business logic. The engine is its `owner` and the only minter/burner. Small attack surface.
- **`DSCEngine`** holds *all* the rules: collateral accounting, USD pricing, health factor,
  redemption, and liquidation. Guards: `ReentrancyGuard`, checks-effects-interactions ordering,
  `SafeERC20`.
- **`OracleLib`** wraps every Chainlink read and **reverts on a stale or incomplete round**, so
  the protocol never acts on a price that is too old.

### Repository layout

```
src/
  DecentralizedStableCoin.sol    # the ERC20 token (mint/burn gated to the engine)
  DSCEngine.sol                  # core: deposit, mint, redeem, burn, liquidate, health factor
  libraries/OracleLib.sol        # Chainlink stale-price / round-completeness guard
script/
  DeployDSC.s.sol                # deploys token + engine, hands DSC ownership to the engine
  HelperConfig.s.sol             # per-network feeds; deploys mocks on anvil
test/
  unit/                          # DSC token + full DSCEngine unit coverage (incl. crash scenario)
  fuzz/                          # Handler + invariant (collateral value ≥ DSC supply) + stateless fuzz
  mocks/                         # ERC20Mock, MockV3Aggregator
```

---

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Install Foundry (forge / cast / anvil)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone, then install dependencies (OpenZeppelin v5, Chainlink) into lib/
forge install

# Build & test
forge build
forge test
forge coverage --report summary
```

Dependencies: `OpenZeppelin/openzeppelin-contracts`,
`smartcontractkit/chainlink-brownie-contracts`, `foundry-rs/forge-std`. Remappings live in
`remappings.txt` / `foundry.toml`.

---

## Test results

`forge test` — **45 passing, 0 failing** (unit + fuzz + invariant):

```
test/unit/DecentralizedStableCoinTest.t.sol   10 passed
test/unit/DSCEngineTest.t.sol                  29 passed   (incl. crash/liquidation + stale oracle)
test/fuzz/DSCEngineFuzz.t.sol                   4 passed   (deposit / mint / redeem properties)
test/fuzz/InvariantsTest.t.sol                  2 passed   (16,384 calls/run, invariant holds)
```

`forge coverage --report summary` (core contracts):

```
| File                            | % Lines          | % Statements     | % Funcs        |
|---------------------------------|------------------|------------------|----------------|
| src/DSCEngine.sol               | 96.33% (105/109) | 97.06% (99/102)  | 96.88% (31/32) |
| src/DecentralizedStableCoin.sol | 100.00% (14/14)  | 100.00% (13/13)  | 100.00% (2/2)  |
| src/libraries/OracleLib.sol     | 100.00% (11/11)  | 100.00% (12/12)  | 100.00% (2/2)  |
| Total (incl. scripts + mocks)   | 93.81%           | 95.87%           | 90.74%         |
```

The **key invariant** — *USD value of collateral held by the engine ≥ total DSC supply* — runs
over thousands of random deposit/mint/redeem sequences without breaking.

---

## Usage on a local node (`anvil` + `cast`)

In one terminal, start a local node:

```bash
anvil
```

In another, deploy. Anvil's first dev account key is public and used here for **local only**:

```bash
forge script script/DeployDSC.s.sol:DeployDSC \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

The deploy prints the addresses. With the deterministic anvil deployment they are (example):

| Contract           | Address                                      |
| ------------------ | -------------------------------------------- |
| DSC token          | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| DSCEngine          | `0x0165878A594ca255338adfA4d48449f69242Eb8F` |
| wETH (mock)        | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| wBTC (mock)        | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |

Then drive it with `cast` (replace addresses with yours):

```bash
RPC=http://localhost:8545
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ME=0xf39Fd6e51aaD88F6F4ce6aB8827279cffFb92266     # anvil account[0]
WETH=0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
ENGINE=0x0165878A594ca255338adfA4d48449f69242Eb8F
DSC=0x5FC8d32690cc91D4c39d9d3abcBD16989F875707

# 1. Get some collateral (mock token), then approve the engine to pull it.
cast send $WETH "mint(address,uint256)" $ME 10ether            --private-key $KEY --rpc-url $RPC
cast send $WETH "approve(address,uint256)" $ENGINE 10ether     --private-key $KEY --rpc-url $RPC

# 2. Deposit 10 wETH ($20,000) and mint 100 DSC in one call.
cast send $ENGINE "depositCollateralAndMintDsc(address,uint256,uint256)" \
  $WETH 10ether 100ether --private-key $KEY --rpc-url $RPC

# 3. Inspect the position.
cast call $DSC    "balanceOf(address)(uint256)" $ME                --rpc-url $RPC   # 100e18 DSC
cast call $ENGINE "getAccountCollateralValue(address)(uint256)" $ME --rpc-url $RPC  # 20000e18 USD
cast call $ENGINE "getHealthFactor(address)(uint256)" $ME          --rpc-url $RPC   # 100e18 (HF 100)
```

To see liquidation, lower the mock price feed and have a second account call
`liquidate(collateral, user, debtToCover)` — see
`test/unit/DSCEngineTest.t.sol::test_CrashScenario_LiquidationProfitsAndKeepsSolvency` for the
exact sequence.

---

## Deploying to Sepolia

1. Copy `.env.example` to `.env` and fill in `SEPOLIA_RPC_URL` and `ETHERSCAN_API_KEY`.
2. Import your deployer key **once** into Foundry's encrypted keystore (never commit a key):

   ```bash
   cast wallet import deployer --interactive   # paste your testnet private key
   ```

3. Deploy and verify on Etherscan:

   ```bash
   source .env
   forge script script/DeployDSC.s.sol:DeployDSC \
     --rpc-url $SEPOLIA_RPC_URL \
     --account deployer \
     --broadcast \
     --verify --etherscan-api-key $ETHERSCAN_API_KEY
   ```

On Sepolia, `HelperConfig` uses the real Chainlink **ETH/USD**
(`0x694AA1769357215DE4FAC081bf1f309aDC325306`) and **BTC/USD**
(`0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43`) feeds. The wETH/wBTC token addresses in
`HelperConfig` are existing Sepolia test tokens — swap in your own if they change.

---

## Security assumptions & known limitations

- **Oracle trust.** DSC is only as honest as its Chainlink feeds. `OracleLib` rejects stale/
  incomplete rounds (**fails closed**), but a *freeze* also blocks liquidations during the exact
  volatile moments you need them. There is no fallback oracle or circuit breaker.
- **Peg is soft.** The peg relies on overcollateralization + liquidation incentives, not a
  redemption/arbitrage mechanism against a basket. Severe, fast crashes (collateral falls below
  100% before liquidators act) could leave bad debt.
- **No protocol fees / DSR / governance** — deliberately out of scope to keep the core tight.
- **Liquidation completeness.** Liquidation is partial-friendly but assumes a liquidator has DSC
  and that the seized-collateral-plus-bonus is available; a fully insolvent position is not
  specially handled.

## Next steps toward production

- Add a **fallback oracle** and a bounded **price-deviation / circuit-breaker** check.
- Handle **bad debt** explicitly (protocol-owned backstop / partial-liquidation accounting when
  collateral < debt).
- Support **partial liquidations** with a minimum-health-factor target and a liquidation queue.
- A formal-verification / **invariant suite expansion** (e.g. Certora, more handler actions
  including price moves and liquidations inside the invariant run).
- A professional **audit**, gas optimization pass, and a deployment/upgrade story.
```
