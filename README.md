# Decentralized Stablecoin Project

This project is a decentralized finance (DeFi) application that implements a stablecoin system. The stablecoin, named DSC (Decentralized Stable Coin), is designed to maintain a 1:1 ratio with USD. The DSCEngine contract is the core of the Decentralized Stable Coin (DSC) system. It governs the main operations of the DSC token and interacts with other components of the system. It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.

## Features

### ERC20 Stablecoin

DSC is implemented as an ERC20 token, allowing for standard token operations such as transfer, approve, and balance queries.

### DSCEngine Contract

The DSCEngine contract serves as the core of the DSC system. It handles essential operations like minting and burning DSC, depositing and redeeming collateral, and calculating user health factors. This contract interacts with Chainlink price feeds to obtain real-time price data for collateral tokens.

### Collateral-backed

DSC is backed by collateral in the form of exogenous assets, including ETH and BTC. This collateralization ensures the stability and security of the stablecoin.

### Algorithmic Minting

The minting of DSC follows an algorithmic approach, contributing to the stability and reliability of the stablecoin.

### Pegged to USD

DSC maintains a 1:1 peg with the USD, providing users with relative stability and predictability in value.

## Getting Started

To get started with the Decentralized Stablecoin project, follow these steps:

1. **Explore the Code**: Familiarize yourself with the DSCEngine contract and the DSC token contract. These contracts define the logic and functionality of the stablecoin system.

2. **Contract Deployment**: Deploy the DSCEngine contract and the DSC token contract on the Ethereum blockchain. Ensure that you have the necessary permissions to deploy and interact with these contracts.

3. **Collateral Management**: Understand the supported collateral tokens and their associated Chainlink price feeds. Configure the system to recognize and work with specific collateral assets.

4. **Minting and Burning**: Explore the minting and burning functionalities of the DSC token. Mint DSC when collateral is deposited, and burn DSC when redeeming collateral.

5. **Integration with Chainlink**: Ensure that the DSCEngine contract is correctly integrated with Chainlink price feeds to obtain accurate and up-to-date price information for collateral tokens.

6. **Testing and Deployment**: Test the system thoroughly in a development environment before considering deployment to the mainnet. Use testnets for initial testing and ensure that all functionalities work as expected.

7. **Documentation and Readme**: Maintain comprehensive documentation, including a well-structured readme file that provides an overview of the project, its features, and guidance for users and developers.

8. **Security Considerations**: Implement best practices for smart contract security to protect against potential vulnerabilities. Consider undergoing a third-party audit for additional security validation.

## Liquidation Process

#### Overview

The liquidation process is a crucial mechanism in the Decentralized Stablecoin (DSC) system designed to maintain system solvency and protect against undercollateralization. Liquidation occurs when a user's health factor falls below a specified threshold, indicating potential insolvency.

#### Key Steps

1. **Health Factor Check**: Before initiating the liquidation process, the DSCEngine contract checks the health factor of the user. If the health factor is above the minimum threshold, no liquidation is needed.

2. **Token Amount Calculation**: The system calculates the amount of collateral tokens required to cover the user's outstanding debt, taking into account a liquidation bonus. The bonus provides an incentive for liquidators.

3. **Collateral Redemption**: The calculated collateral amount, including the bonus, is redeemed from the user's collateral deposits. The collateral is then transferred to the liquidator.

4. **DSC Burn**: The user's outstanding DSC debt is burned, reducing the overall DSC supply.

5. **Health Factor Verification**: After liquidation, the health factor of the user is re-evaluated. If the health factor has not improved, the process is considered unsuccessful.

6. **Liquidator Balances Update**: The DSCEngine contract updates the liquidator's balances by deducting the debt covered and collateral redeemed.

7. **Threshold Warning**: If the collateral price drops more than 40% from the initial liquidated user's collateral price, a warning is issued and the processed revert, indicating potential system instability.

#### Notes

- This version of DeFi Stablecoin implements a different liquidation process. Key distinctions may be observed when compared to other implementations, such as those by [Patrick Collins](https://github.com/Cyfrin/foundry-defi-stablecoin-f23).
