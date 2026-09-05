import Foundation
import ObjectiveC

/// 迷你测试框架。
/// 环境只有 CommandLineTools（无完整 Xcode，XCTest/Testing 模块不可用），
/// 因此用 ObjC runtime 反射枚举 ZTestCase 子类的 test 开头方法执行。
/// 断言失败记录后继续执行；数组越界等真崩溃会中断 runner（输出已收集的失败）。

public final class ZTestState {
    static var failures: [String] = []
    static var currentTest = "<none>"
    static func record(_ message: String) {
        failures.append(message)
        print("  FAIL [\(currentTest)] \(message)")
    }
}

public class ZTestCase: NSObject {}

public func ztAssertTrue(_ condition: Bool, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    if !condition {
        ZTestState.record("\(label.isEmpty ? "expected true" : label) (\(file):\(line))")
    }
}

public func ztAssertFalse(_ condition: Bool, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    ztAssertTrue(!condition, label.isEmpty ? "expected false" : label, file: file, line: line)
}

public func ztAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    if actual != expected {
        ZTestState.record("\(label.isEmpty ? "" : "\(label) ")expected \(expected), got \(actual) (\(file):\(line))")
    }
}

public func ztAssertNil<T>(_ value: T?, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    if value != nil {
        ZTestState.record("\(label.isEmpty ? "expected nil" : label), got \(String(describing: value)) (\(file):\(line))")
    }
}

public func ztAssertNotNil<T>(_ value: T?, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    if value == nil {
        ZTestState.record("\(label.isEmpty ? "expected non-nil" : label), got nil (\(file):\(line))")
    }
}

public func ztAssertGreaterThan<T: Comparable>(_ actual: T, _ bound: T, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    if actual <= bound {
        ZTestState.record("\(label.isEmpty ? "" : "\(label) ")expected > \(bound), got \(actual) (\(file):\(line))")
    }
}

public func ztAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ label: String = "", file: String = #fileID, line: UInt = #line) {
    do {
        _ = try expression()
        ZTestState.record("\(label.isEmpty ? "expected error" : label), but no error was thrown (\(file):\(line))")
    } catch {
        // 预期路径
    }
}

enum ZTestRunner {
    /// 不能用 NSObject.isSubclass(of:)：对 Swift 根类（ObjC 名 'Object'）会触发消息转发崩溃；
    /// 用 C API 沿 superclass 链判断对任何类都安全。
    static func inheritsFrom(_ cls: AnyClass, _ root: AnyClass) -> Bool {
        var current: AnyClass? = cls
        while let candidate = current {
            if candidate == root { return true }
            current = class_getSuperclass(candidate)
        }
        return false
    }

    static func allSubclasses(of superclass: AnyClass) -> [AnyClass] {
        let total = objc_getClassList(nil, 0)
        guard total > 0, let classes = malloc(Int(total) * MemoryLayout<AnyClass>.size)?
            .assumingMemoryBound(to: AnyClass.self) else { return [] }
        defer { free(classes) }
        let actual = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(classes), total)
        var result: [AnyClass] = []
        for index in 0..<Int(actual) {
            let candidate: AnyClass = classes[index]
            if candidate != superclass, inheritsFrom(candidate, superclass) {
                result.append(candidate)
            }
        }
        return result
    }

    static func run() -> Never {
        var total = 0
        let classes = allSubclasses(of: ZTestCase.self)
            .sorted { NSStringFromClass($0) < NSStringFromClass($1) }
        for cls in classes {
            // 必须经 init 构造：仅 alloc() 不执行 Swift 存储属性默认值初始化器，
            // 属性会读到未初始化内存（曾导致测试假阳性）。
            let instance = (cls as! NSObject.Type).init()
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
            var selectors: [Selector] = []
            for index in 0..<Int(methodCount) {
                let selector = method_getName(methods[index])
                if NSStringFromSelector(selector).hasPrefix("test") {
                    selectors.append(selector)
                }
            }
            free(methods)
            for selector in selectors.sorted(by: { NSStringFromSelector($0) < NSStringFromSelector($1) }) {
                ZTestState.currentTest = "\(NSStringFromClass(cls)).\(NSStringFromSelector(selector))"
                let implementation = class_getMethodImplementation(cls, selector)
                let function = unsafeBitCast(implementation, to: (@convention(c) (NSObject, Selector) -> Void).self)
                function(instance, selector)
                total += 1
            }
        }
        print("----")
        if ZTestState.failures.isEmpty {
            print("ALL \(total) TESTS PASSED")
            exit(0)
        }
        print("\(ZTestState.failures.count) assertion failure(s) across \(total) tests")
        exit(1)
    }
}

@main
struct TestMain {
    static func main() {
        ZTestRunner.run()
    }
}
