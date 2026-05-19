import Testing
import Foundation
@testable import OrreryCore

@Suite("EnvironmentStore user memory paths")
struct EnvironmentStoreUserMemoryTests {

    @Test("userMemoryDir is ~/.orrery/user/memory under the store home")
    func userMemoryDirPath() {
        let home = URL(fileURLWithPath: "/tmp/fake-orrery-home")
        let store = EnvironmentStore(homeURL: home)
        #expect(store.userMemoryDir().path == "/tmp/fake-orrery-home/user/memory")
    }
}
