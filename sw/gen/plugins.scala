// NaxGen --scala-file injection. Predefined variables: resetVector / xlen / args / memoryRegions
// Constraint: only CPU plugins here; the I$/D$/pBus TileLink ports are derived by TilelinkNaxRiscvFiber.
// NOTE: this file must stay pure ASCII -- NaxGen reads it with scala.io.Source.fromFile using the JVM
//       default charset (GBK on this machine), so UTF-8 non-ASCII bytes abort generation with
//       java.nio.charset.MalformedInputException.
// NOTE: import spinal.core._ is mandatory -- `downto` and the Int => UInt literal implicit both live in
//       the spinal.core package object, and NaxGen's interpreter prelude does not import it.
import spinal.core._
import naxriscv.Config

plugins ++= Config.plugins(
  resetVector        = resetVector,
  withRdTime         = true,
  ioRange            = a => a(31 downto 28) === 0xF,
  memRange           = a => a(31 downto 29) === 4,
  fetchRange         = a => a(31 downto 29) === 4,
  aluCount           = 2,
  decodeCount        = 2,
  withRvc            = true,
  withMmu            = true,
  withSupervisor     = true,
  withUser           = true,
  xlen               = xlen,
  withFloat          = false,
  withDouble         = false,
  withDistributedRam = true,
  withLsu2           = true,
  withDebug          = false,
  withCoherency      = true
)
