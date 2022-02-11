import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { BigNumber, BigNumberish } from "ethers";
import { ethers } from "hardhat";
import { ERC20Token, ERC20Token__factory, IDO, IDO__factory } from "../src/types";

describe("Staking", function () {
    let accounts: SignerWithAddress[];
    let owner: SignerWithAddress;
    let tokenBuy: ERC20Token;
    let tokenSell: ERC20Token;
    let ido: IDO;
    let conversionRate = ethers.utils.parseEther("1");
    const MINTER_ROLE = ethers.utils.id("MINTER_ROLE");
    const BURNER_ROLE = ethers.utils.id("BURNER_ROLE");

    before(async function () {
        accounts = await ethers.getSigners();
        owner = accounts[0];
    });

    beforeEach(async function () {
        tokenBuy = await getTokenContract(owner, "BNB", "BNB");
        tokenSell = await getTokenContract(owner, "SellToken", "STK");
        ido = await getIDOContract(owner);
    });

    it("Should create campaign", async function () {
        const startTime = BigNumber.from((await ethers.provider.getBlock("latest"))['timestamp']);

        // percentage less than 100
        let vestings = [{ percent: ethers.utils.parseEther("40"), timestamp: (30 * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 2) * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 3) * (60 * 60 * 24)) }];
        await expect(ido.create(tokenBuy.address, tokenSell.address, ethers.utils.parseEther("500"), ethers.utils.parseEther("1000"), ethers.utils.parseEther("2000"), ethers.utils.parseEther("5000"), conversionRate, startTime, startTime.add((60 * 60 * 3)), vestings))
            .to.revertedWith("Total percentage should be 100");

        // percentage more than 100
        vestings = [{ percent: ethers.utils.parseEther("75"), timestamp: (30 * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 2) * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 3) * (60 * 60 * 24)) }];
        await expect(ido.create(tokenBuy.address, tokenSell.address, ethers.utils.parseEther("500"), ethers.utils.parseEther("1000"), ethers.utils.parseEther("2000"), ethers.utils.parseEther("5000"), conversionRate, startTime, startTime.add((60 * 60 * 3)), vestings))
            .to.revertedWith("Total percentage should be 100");

        // percentage equal to 100
        vestings = [{ percent: ethers.utils.parseEther("50"), timestamp: (30 * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 2) * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 3) * (60 * 60 * 24)) }];
        await ido.create(tokenBuy.address, tokenSell.address, ethers.utils.parseEther("500"), ethers.utils.parseEther("1000"), ethers.utils.parseEther("2000"), ethers.utils.parseEther("5000"), conversionRate, startTime, startTime.add((60 * 60 * 3)), vestings);
    });

    it("Should join to campaign", async function () {
        const firstJoinAmount = ethers.utils.parseEther("1000");

        // owner mint and approve 
        await tokenBuy.mint(owner.address, firstJoinAmount.mul(5));
        await tokenBuy.approve(ido.address, firstJoinAmount.mul(5));

        // acc1 mint and approve 
        await tokenBuy.mint(accounts[1].address, firstJoinAmount);
        await tokenBuy.connect(accounts[1]).approve(ido.address, firstJoinAmount);

        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 0

        await expect(ido.join(0, ethers.utils.parseEther("400"))) // Less than min alloc
            .to.revertedWith("Amount is not right");

        await expect(ido.join(0, ethers.utils.parseEther("1100"))) // More than max alloc
            .to.revertedWith("Amount is not right");

        await expect(await ido.join(0, firstJoinAmount))
            .to.emit(tokenBuy, "Transfer")
            .withArgs(owner.address, ido.address, firstJoinAmount);

        await ido.join(0, firstJoinAmount); // 2000
        await ido.join(0, firstJoinAmount); // 3000
        await ido.connect(accounts[1]).join(0, firstJoinAmount); // 4000 , account1 sent 1000
        await ido.join(0, firstJoinAmount); // 5000

        expect((await ido.getUserInfo(0, owner.address))['allocation'])
            .equal(ethers.utils.parseEther("4000"));
        expect((await ido.getUserInfo(0, accounts[1].address))['allocation'])
            .equal(ethers.utils.parseEther("1000"));

        expect((await ido.connect(accounts[1]).getCampaign(0))['totalAlloc'])
            .equal(ethers.utils.parseEther("5000"));

        await expect(ido.join(0, firstJoinAmount)) // More than max goal
            .to.revertedWith("Amount exceeds the goal");

        await simulateTimePassed(30 * (60 * 60 * 24));

        await expect(ido.join(0, firstJoinAmount)) // More than max goal
            .to.revertedWith("You cannot join now");

        // test for error
        await ido.approve(0, accounts[2].address);
        await expect(ido.join(0, firstJoinAmount))
            .to.revertedWith("Campaign is not active");
    });

    it("Should approve campaign", async function () {
        const firstJoinAmount = ethers.utils.parseEther("1000");

        // owner mint and approve 
        await tokenBuy.mint(owner.address, firstJoinAmount.mul(3));
        await tokenBuy.approve(ido.address, firstJoinAmount.mul(3));

        // acc1 mint and approve 
        await tokenBuy.mint(accounts[1].address, firstJoinAmount.mul(2));
        await tokenBuy.connect(accounts[1]).approve(ido.address, firstJoinAmount.mul(2));

        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 0
        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 1

        // campaign 0
        await ido.join(0, firstJoinAmount); // 1000
        await ido.join(0, firstJoinAmount); // 2000
        await ido.join(0, firstJoinAmount); // 3000

        // campaign 1
        await ido.connect(accounts[1]).join(1, firstJoinAmount); // 1000
        await ido.connect(accounts[1]).join(1, firstJoinAmount.div(2)); // 1500

        await expect(ido.approve(0, accounts[2].address)) // More than max goal
            .to.revertedWith("Too early to approve");

        await simulateTimePassed(30 * (60 * 60 * 24));

        expect((await ido.getCampaign(0))['status'])
            .equal(1); // CampaignStatus.ACTIVE
        expect((await ido.getCampaign(1))['status'])
            .equal(1); // CampaignStatus.ACTIVE

        await expect(await ido.approve(0, accounts[2].address))
            .to.emit(tokenBuy, "Transfer")
            .withArgs(ido.address, accounts[2].address, ethers.utils.parseEther("3000")); // IDO successful send all the funds to the address

        expect((await ido.getCampaign(0))['status'])
            .equal(2); // CampaignStatus.SUCCESS

        await ido.approve(1, accounts[2].address); // approve campaign 1 (should be FAIL)

        expect((await ido.getCampaign(1))['status'])
            .equal(3); // CampaignStatus.FAIL
    });

    it("Should refund", async function () {
        const firstJoinAmount = ethers.utils.parseEther("1000");

        // owner mint and approve 
        await tokenBuy.mint(owner.address, firstJoinAmount.mul(3));
        await tokenBuy.approve(ido.address, firstJoinAmount.mul(3));

        // acc1 mint and approve 
        await tokenBuy.mint(accounts[1].address, firstJoinAmount.mul(2));
        await tokenBuy.connect(accounts[1]).approve(ido.address, firstJoinAmount.mul(2));

        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 0
        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 1

        // campaign 0
        await ido.join(0, firstJoinAmount); // 1000
        await ido.join(0, firstJoinAmount); // 2000
        await ido.join(0, firstJoinAmount); // 3000

        // campaign 1
        await ido.connect(accounts[1]).join(1, firstJoinAmount); // 1000
        await ido.connect(accounts[1]).join(1, firstJoinAmount.div(2)); // 1500

        await simulateTimePassed(30 * (60 * 60 * 24));

        await ido.approve(0, accounts[2].address); // SUCCESS
        await ido.approve(1, accounts[2].address); // FAIL

        await expect(ido.refund(0))
            .to.revertedWith("Campaign did not fail"); // campaign successful

        await expect(ido.refund(1))
            .to.revertedWith("No allocation to refund"); // no funds send from owner acc

        await expect(await ido.connect(accounts[1]).refund(1))
            .to.emit(tokenBuy, "Transfer")
            .withArgs(ido.address, accounts[1].address, ethers.utils.parseEther("1500"));

        await expect(ido.connect(accounts[1]).refund(1))
            .to.revertedWith("No allocation to refund"); // try to refund again
    });

    it("Should claim", async function () {
        const firstJoinAmount = ethers.utils.parseEther("1000");

        // tokenSell mint and approve
        await tokenSell.mint(ido.address, firstJoinAmount.mul(12));
        await tokenBuy.approve(ido.address, firstJoinAmount.mul(12));

        // owner mint and approve 
        await tokenBuy.mint(owner.address, firstJoinAmount.mul(3));
        await tokenBuy.approve(ido.address, firstJoinAmount.mul(3));

        // acc1 mint and approve 
        await tokenBuy.mint(accounts[1].address, firstJoinAmount.mul(2));
        await tokenBuy.connect(accounts[1]).approve(ido.address, firstJoinAmount.mul(2));

        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 0
        conversionRate = ethers.utils.parseEther("3"); // means 1 tokenbuy = 3 tokensell
        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 1
        await createCampaign(ido, tokenBuy, tokenSell, conversionRate, owner); // id 2 (to fail)

        // campaign 0
        await ido.join(0, firstJoinAmount); // 1000
        await ido.join(0, firstJoinAmount); // 2000
        await ido.join(0, firstJoinAmount); // 3000

        // campaign 1
        await ido.connect(accounts[1]).join(1, firstJoinAmount); // 1000
        await ido.connect(accounts[1]).join(1, firstJoinAmount); // 2000

        await simulateTimePassed(30 * (60 * 60 * 24));

        await ido.approve(0, accounts[2].address); // SUCCESS
        await ido.approve(1, accounts[2].address); // SUCCESS
        await ido.approve(2, accounts[2].address); // FAIL

        await simulateTimePassed(30 * (60 * 60 * 24)); // 1 month passed

        await expect(ido.claim(2))
            .to.revertedWith("Campaign is not successful");

        await expect(await ido.claim(0))
            .to.emit(tokenSell, "Transfer")
            .withArgs(ido.address, owner.address, ethers.utils.parseEther("1500"));


        await simulateTimePassed(30 * (60 * 60 * 24)); // 1 month passed

        await expect(await ido.claim(0))
            .to.emit(tokenSell, "Transfer")
            .withArgs(ido.address, owner.address, ethers.utils.parseEther("750"));

        await simulateTimePassed(30 * (60 * 60 * 24)); // 1 month passed

        await expect(await ido.claim(0))
            .to.emit(tokenSell, "Transfer")
            .withArgs(ido.address, owner.address, ethers.utils.parseEther("750"));

        await expect(await ido.connect(accounts[1]).claim(1))
            .to.emit(tokenSell, "Transfer")
            .withArgs(ido.address, accounts[1].address, ethers.utils.parseEther("6000")); // because never claimed during 3 months and 3 times conversion rate
    });


});

async function createCampaign(idoContract: IDO, tokenBuy: ERC20Token, tokenSell: ERC20Token, conversionRate: BigNumberish, owner: SignerWithAddress) {
    const vestings = [{ percent: ethers.utils.parseEther("50"), timestamp: (30 * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 2) * (60 * 60 * 24)) }, { percent: ethers.utils.parseEther("25"), timestamp: ((30 * 3) * (60 * 60 * 24)) }];
    const startTime = BigNumber.from((await ethers.provider.getBlock("latest"))['timestamp']);
    return idoContract.connect(owner).create(tokenBuy.address, tokenSell.address, ethers.utils.parseEther("500"), ethers.utils.parseEther("1000"), ethers.utils.parseEther("2000"), ethers.utils.parseEther("5000"), conversionRate, startTime, startTime.add((60 * 60 * 3)), vestings);
};

async function getTokenContract(owner: SignerWithAddress, tokenName: string, tokenSymbol: string) {
    const factory = new ERC20Token__factory(owner);
    const contract = await factory.deploy(tokenName, tokenSymbol);
    await contract.deployed();

    return contract;
}

async function getIDOContract(owner: SignerWithAddress) {
    const factory = new IDO__factory(owner);
    const contract = await factory.deploy();
    await contract.deployed();

    return contract;
}

async function simulateTimePassed(duration: BigNumberish) {
    await ethers.provider.send('evm_increaseTime', [duration]);
    await ethers.provider.send('evm_mine', []);
}