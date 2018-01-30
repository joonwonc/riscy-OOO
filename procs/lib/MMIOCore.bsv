import Types::*;
import ProcTypes::*;
import MMIOAddrs::*;
import CacheUtils::*;
import Fifo::*;

// local MMIO logic in each core (MMIOCore)
// Every MMIO req from the core is directly passed to the platform, while this
// logic handles req from the platform when platform is processing core req or
// posting timer interrupt.

interface MMIOCoreToPlatform;
    interface FifoDeq#(MMIOCRq) cRq;
    interface FifoEnq#(MMIOPRs) pRs;
    interface FifoEnq#(MMIOPRq) pRq;
    interface FifoDeq#(MMIOCRs) cRs;
    // core keeps a copy of the mtime reg. This method allows the platform to
    // inform the core to change time CSR.
    method Action setTime(Data t);
endinterface

interface MMIOCore;
    // methods to other parts in the core
    // is the PHYSICAL addr an MMIO addr
    method Bool isMMIOAddr(Addr addr);
    // for mem exe pipeline to send/recv MMIO req/resp
    interface FifoEnq#(MMIOCRq) mmioReq;
    interface FifoDeq#(MMIOPRs) mmioResp;
    // set tohost & fromhost addr
    method Action setHtifAddrs(Addr toHost, Addr fromHost);

    // methods to platform
    interface MMIOCoreToPlatform toP;
endinterface

interface MMIOCoreInput;
    // MMIOCore needs to access MSIP and MTIP CSRs
    method Bit#(1) getMSIP;
    method Action setMSIP(Bit#(1) v);
    method Action setMTIP(Bit#(1) v);
    // guards for accessing MSIP or MTIP
    method Bool noInflightCSRInst;
    method Bool noInflightInterrupt;
    // MMIOCore needs to pass mtime to CSRF
    method Action setTime(Data t);
endinterface

module mkMMIOCore#(MMIOCoreInput inIfc)(MMIOCore);
    // HTIF mem mapped addrs
    Reg#(DataAlignedAddr) toHostAddr <- mkReg(0);
    Reg#(DataAlignedAddr) fromHostAddr <- mkReg(0);
    // FIFOs connected to platform
    Fifo#(1, MMIOCRq) cRqQ <- mkCFFifo;
    Fifo#(1, MMIOPRs) pRsQ <- mkCFFifo;
    Fifo#(1, MMIOPRq) pRqQ <- mkCFFifo;
    Fifo#(1, MMIOCRs) cRsQ <- mkCFFifo;

    // PRq from platform will access MSIP or MTIP. As explained in CSRF,
    // accessing these bits may break the atomicity of CSRXXX inst or interrupt
    // handling, so we need to check for them. Note that exception handling
    // does not touch MSIP/MTIP. Besides, a inst with exception may be after
    // the MMIO inst that accesses its own MSIP. Waiting for the clear of
    // exception may cause deadlock.
    rule handlePRq(inIfc.noInflightCSRInst && inIfc.noInflightInterrupt);
        pRqQ.deq;
        MMIOPRq req = pRqQ.first;
        MMIOCRs resp = MMIOCRs {data: ?};
        case(req.target)
            MSIP: begin
                if(req.write) begin
                    inIfc.setMSIP(req.data);
                end
                else begin
                    resp.data = inIfc.getMSIP;
                end
            end
            MTIP: begin
                if(req.write) begin
                    inIfc.setMTIP(req.data);
                end
                else begin
                    doAssert(False, "platform can only write MTIP");
                end
            end
            default: doAssert(False, "unknown target");
        endcase
        // resp to platform
        cRsQ.enq(resp);
    endrule

    method Bool isMMIOAddr(Addr addr);
        let a = getDataAlignedAddr(addr);
        return a < mainMemBaseAddr || a == toHostAddr || a == fromHostAddr;
    endmethod

    interface mmioReq = toFifoEnq(cRqQ);
    interface mmioResp = toFifoDeq(pRsQ);

    method Action setHtifAddrs(Addr toHost, Addr fromHost);
        toHostAddr <= getDataAlignedAddr(toHost);
        fromHostAddr <= getDataAlignedAddr(fromHost);
    endmethod

    interface MMIOCoreToPlatform toP;
        interface cRq = toFifoDeq(cRqQ);
        interface pRs = toFifoEnq(pRsQ);
        interface pRq = toFifoEnq(pRqQ);
        interface cRs = toFifoDeq(cRsQ);
        method setTime = inIfc.setTime;
    endinterface
endmodule

