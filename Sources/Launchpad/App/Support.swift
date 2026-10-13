import Foundation

/// 延时执行;返回的任务被取消就不跑
@MainActor
@discardableResult
func delayed(_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        work()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
