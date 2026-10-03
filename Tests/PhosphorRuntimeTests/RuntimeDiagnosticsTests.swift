import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
@testable import PhosphorRuntime
import Testing

@Suite("Runtime diagnostics", .enabled(if: metalDeviceAvailable))
struct RuntimeDiagnosticsTests {
    /// Editors default-construct a runtime and load the document a moment
    /// later. That placeholder used to report `missingOutput("image")`, which
    /// the UI flashed as a red banner until the first load replaced it (#97).
    @Test("A placeholder runtime reports no diagnostics")
    @MainActor
    func placeholderRuntimeIsQuiet() {
        let runtime = PhosphorRuntime()
        #expect(runtime.diagnostics.isEmpty)
    }

    /// The suppression is keyed on there being no source at all, so a runtime
    /// built from real content still reports its problems.
    @Test("A runtime with real source still reports diagnostics")
    @MainActor
    func realSourceStillDiagnoses() {
        let runtime = PhosphorRuntime(
            configuration: PhosphorConfiguration(output: "image"),
            source: "// no kernels here\n"
        )
        #expect(runtime.diagnostics.contains { diagnostic in
            if case .missingOutput = diagnostic { return true }
            return false
        })
    }
}
