// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract TestnetToken is ERC20 {
    address public faucet;
    address public owner;

    modifier onlyAuthorized() {
        require(msg.sender == owner || msg.sender == faucet, "Not authorized to mint");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol, _decimals) {
        owner = msg.sender;
    }

    function setFaucet(address _faucet) external {
        require(msg.sender == owner, "Only owner can set faucet");
        faucet = _faucet;
    }

    function mint(address to, uint256 amount) external onlyAuthorized {
        _mint(to, amount);
    }
}
