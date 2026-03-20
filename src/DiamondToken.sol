// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract DiamondToken is ERC20, Ownable {
   
    string public certificateId;

  
    uint256 public caratWeight;

    bool public certified;

    address public certifier;

   
    constructor(
        string memory name,
        string memory symbol,
        string memory _certificateId,
        uint256 _caratWeight,
        address _certifier
    ) ERC20(name, symbol) Ownable(msg.sender) {
        certificateId = _certificateId;
        caratWeight = _caratWeight;
        certifier = _certifier;
    }


    modifier onlyCertifier() {
        require(msg.sender == certifier, "DiamondToken: not certifier");
        _;
    }


    function certify() external onlyCertifier {
        certified = true;
        emit Certified(msg.sender, certificateId);
    }

    function revokeCertification() external onlyCertifier {
        certified = false;
        emit CertificationRevoked(msg.sender);
    }

   
    function setCertifier(address newCertifier) external onlyOwner {
        emit CertifierUpdated(certifier, newCertifier);
        certifier = newCertifier;
    }

   
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

   
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
