// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

@_implementationOnly import CoreFoundation

private protocol _UndoFlags : AnyObject {
    var isDiscardable: Bool { get set }
    var actionName: String { get set }
}

private protocol _Undoable {
    var flags: _UndoFlags { get }
}

private protocol _UndoMark : _Undoable {
    var isBeginMark: Bool { get }
}

/**
 A general-purpose recorder of operations that enables undo and redo.
 
 You register an undo operation by calling one of the methods described in
 [Registering Undo Operations](https://developer.apple.com/documentation/foundation/undomanager#1663976).
 You specify the name of the object that’s changing (or the owner of that object) and provide a
 closure, method, or invocation to revert its state.
 
 After you register an undo operation, you can call `undo()` on the undo manager to revert
 to the state of the last undo operation. When undoing an action, `UndoManager` saves the
 operations you reverted to so that you can call `redo()` automatically.
 
 `UndoManager` also as a general-purpose state manager, which can be used to undo and redo many kinds
 of actions. For example, an interactive command-line utility could use this class to undo the last command
 run, or a networking library could undo a request by sending another request that
 invalidates the previous one.
 
 - Note: In swift-corelibs-foundation, `prepare(withInvocationTarget:)` and
 `registerUndo(withTarget:selector:object:)` are unavailable since they rely on the
 Objective-C runtime
 */
open class UndoManager : NSObject {
    private var _undoStack = _UndoStack()
    private var _redoStack = _UndoStack()
    private var _currentUndoingOperation: _UndoOperation?
    private var _currentRedoingOperation: _UndoOperation?

    private var _cfRunLoopEntryObserverStorage: AnyObject!
    private var _cfRunLoopExitObserverStorage: AnyObject!

    private var _cfRunLoopEntryObserver: CFRunLoopObserver {
        get { _cfRunLoopEntryObserverStorage as! CFRunLoopObserver }

        set { _cfRunLoopEntryObserverStorage = newValue }
    }

    private var _cfRunLoopExitObserver: CFRunLoopObserver {
        get { _cfRunLoopExitObserverStorage as! CFRunLoopObserver }

        set { _cfRunLoopExitObserverStorage = newValue }
    }
    
    private var _registrationCounter = 1
    
    /**
     A Boolean value that indicates whether the receiver automatically creates undo groups around each
     pass of the run loop.
     
     `true` if the receiver automatically creates undo groups around each pass of the run loop, otherwise
     `false`.
     
     The default is `true`. If you turn automatic grouping off, you must close groups explicitly before
     invoking either `undo()` or `undoNestedGroup()`.
     */
    open var groupsByEvent = true {
        didSet { processRunLoopObservers(groupsByEvent ? CFRunLoopAddObserver : CFRunLoopRemoveObserver) }
    }
    
    /**
     The modes governing the types of input handled during a cycle of the run loop.
     
     An array of string constants specifying the current run-loop modes.
     
     By default, the sole run-loop mode is `.default` (which excludes data from NSConnection objects).
     Some examples of other uses are to limit the input to data received during a mouse-tracking session by
     setting the mode to `.eventTracking`, or limit it to data received from a modal panel with
     `.modalPanel`.
     */
    open var runLoopModes: [RunLoop.Mode] = [.default] {
        willSet { processRunLoopObservers(CFRunLoopRemoveObserver) }
        
        didSet {
            guard groupsByEvent else { return }
            processRunLoopObservers(CFRunLoopAddObserver)
        }
    }
    
    /**
     The number of nested undo groups (or redo groups, if Redo was invoked last) in the current event loop.
     
     An integer indicating the number of nested groups. If 0 is returned, there is no open undo or redo group.
     */
    open var groupingLevel: Int { !isUndoing ? _undoStack.groupingLevel : _redoStack.groupingLevel }
    
    /**
     A Boolean value that indicates whether the recording of undo operations is enabled.
     
     `true` if registration is enabled; otherwise, `false`.
     
     The default is `true`.
     */
    open var isUndoRegistrationEnabled: Bool { _registrationCounter == 1 }
    
    /**
     The maximum number of top-level undo groups the receiver holds.
     
     An integer specifying the number of undo groups. A limit of `0` indicates no limit, so old undo groups
     are never dropped.
     
     When ending an undo group results in the number of groups exceeding this limit, the oldest groups are
     dropped from the stack. The default is `0`.
     
     If you change the limit to a level below the prior limit, old undo groups are immediately dropped.
     */
    open var levelsOfUndo = 0 {
        didSet {
            _undoStack.setLimit(levelsOfUndo)
            _redoStack.setLimit(levelsOfUndo)
        }
    }
    
    /**
     A Boolean value that indicates whether the receiver has any actions to undo.
     
     `true` if the receiver has any actions to undo, otherwise `false`.
     
     The return value does not mean you can safely invoke `undo()` or
     `undoNestedGroup()`—you may have to close open undo groups first.
     */
    open var canUndo: Bool { _undoStack.count != 0 }
    
    /**
     A Boolean value that indicates whether the receiver has any actions to redo.
     
     `true` if the receiver has any actions to redo, otherwise `false`.
     
     Because any undo operation registered clears the redo stack, this method
     posts an `NSUndoManagerCheckpoint` to allow clients to apply their
     pending operations before testing the redo stack.
     */
    open var canRedo: Bool {
        _postCheckpointNotification()
        return _redoStack.count != 0
    }
    
    /**
     Returns a Boolean value that indicates whether the receiver is in the process of performing its
     `undo()` or `undoNestedGroup()` method.
     
     `true` if the method is being performed, otherwise `false`.
     */
    open private(set) var isUndoing = false
    
    /**
     Returns a Boolean value that indicates whether the receiver is in the process of performing
     its `redo()` method.
     
     `true` if the method is being performed, otherwise `false`.
     */
    open private(set) var isRedoing = false
    
    /**
     Boolean value that indicates whether the next undo action is discardable.
     
     `true` if the action is discardable; `false` otherwise.
     
     Specifies that the latest undo action may be safely discarded when a document can not be saved for
     any reason. These are typically actions that don’t affect persistent state.
     
     An example might be an undo action that changes the viewable area of a document.
     */
    open var undoActionIsDiscardable: Bool { _undoStack.lastFlags?.isDiscardable ?? false }
    
    /**
     Boolean value that indicates whether the next redo action is discardable.
     
     `true` if the action is discardable; `false` otherwise.
     
     Specifies that the latest redo action may be safely discarded when a document can not be saved for
     any reason. These are typically actions that don’t affect persistent state.
     
     An example might be an redo action that changes the viewable area of a document.
     */
    open var redoActionIsDiscardable: Bool { _redoStack.lastFlags?.isDiscardable ?? false }
    
    /**
     The name identifying the undo action.
     
     The undo action name. Returns an empty string (`""`) if no action name has been assigned or if
     there is nothing to undo.
     
     For example, if the menu title is “Undo Delete,” the string returned is “Delete.”
     */
    open var undoActionName: String { _undoStack.lastFlags?.actionName ?? "" }
    
    /**
     The name identifying the redo action.
     
     The redo action name. Returns an empty string (`""`) if no action name has been assigned or if there
     is nothing to redo.
     
     For example, if the menu title is “Redo Delete,” the string returned is “Delete.”
     */
    open var redoActionName: String { _redoStack.lastFlags?.actionName ?? "" }
    
    /**
     The complete title of the Undo menu command, for example, “Undo Paste.”
     
     Returns “Undo” if no action name has been assigned or `nil` if there is nothing to undo.
     */
    open var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: _undoStack.lastFlags?.actionName ?? "") }
    
    /**
     The complete title of the Redo menu command, for example, “Redo Paste.”
     
     Returns “Redo” if no action name has been assigned or `nil` if there is nothing to redo.
     */
    open var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: _redoStack.lastFlags?.actionName ?? "") }
    
    private var _description: String {
        return "NSUndoManager \(Unmanaged.passUnretained(self).toOpaque())"
    }
    
    override public init() {
        super.init()
        #if os(macOS) || os(iOS)
        let entry = kCFRunLoopEntry
        let exit = kCFRunLoopExit
        #else
        let entry = UInt(kCFRunLoopEntry)
        let exit = UInt(kCFRunLoopExit)
        #endif
        _cfRunLoopEntryObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, entry, true, 0, { [weak self] observer, activity in
            #if os(macOS) || os(iOS)
            guard activity == .entry, self?.groupsByEvent == true else { return }
            #else
            guard activity == UInt(kCFRunLoopEntry), self?.groupsByEvent == true else { return }
            #endif
            self?.beginUndoGrouping()
        })
        
        _cfRunLoopExitObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, exit, true, 0, { [weak self] observer, activity in
            #if os(macOS) || os(iOS)
            guard activity == .exit, self?.groupsByEvent == true else { return }
            #else
            guard activity == UInt(kCFRunLoopExit), self?.groupsByEvent == true else { return }
            #endif
            self?.endUndoGrouping()
        })
        
        processRunLoopObservers(CFRunLoopAddObserver)
    }
    
    deinit {
        processRunLoopObservers(CFRunLoopRemoveObserver)
    }
    
    /**
     Marks the beginning of an undo group.
     
     All individual undo operations before a subsequent `endUndoGrouping()` message are grouped
     together and reversed by a later `undo()` message. By default undo groups are begun automatically
     at the start of the event loop, but you can begin your own undo groups with this method, and nest them
     within other groups.
     
     This method posts an `NSUndoManagerCheckpoint` unless a top-level undo is in progress.
     It posts an `NSUndoManagerDidOpenUndoGroup` if a new group was successfully created.
     */
    open func beginUndoGrouping() {
        _beginUndoGrouping()
        NotificationCenter.default.post(name: .NSUndoManagerDidOpenUndoGroup, object: self)
    }
    
    private func _beginUndoGrouping() {
        _undoStack.markBegin()
        if groupingLevel > 1 {
            _postCheckpointNotification()
        }
    }
    
    /**
     Marks the end of an undo group.
     
     All individual undo operations back to the matching `beginUndoGrouping()` message are grouped
     together and reversed by a later `undo()` or `undoNestedGroup()` message. Undo groups can
     be nested, thus providing functionality similar to nested transactions. Raises an
     `NSInternalInconsistencyException` if there’s no `beginUndoGrouping()` message in
     effect.
     
     This method posts an `NSUndoManagerCheckpoint` and an
     `NSUndoManagerWillCloseUndoGroup` just before the group is closed.
     */
    open func endUndoGrouping() {
        _postCheckpointNotification()
        NotificationCenter.default.post(name: .NSUndoManagerWillCloseUndoGroup,
                                        object: self,
                                        userInfo: [NSUndoManagerGroupIsDiscardableKey: NSNumber(booleanLiteral: _undoStack.lastFlags?.isDiscardable ?? false)])
        _endUndoGroup()
        NotificationCenter.default.post(name: .NSUndoManagerDidCloseUndoGroup, object: self)
    }
    
    private func _endUndoGroup() {
        do {
            try _undoStack.markEnd()
        } catch {
            _raiseException(message: "endUndoGrouping called with no matching begin")
        }
        if groupingLevel >= 1 {
            _postCheckpointNotification()
        }
    }
    
    /**
     Disables the recording of undo operations.
     
     This method can be invoked multiple times by multiple clients. The `enableUndoRegistration()`
     method must be invoked an equal number of times to re-enable undo registration.
     */
    open func disableUndoRegistration() {
        _registrationCounter -= 1
        if _registrationCounter == 0 {
            processRunLoopObservers(CFRunLoopRemoveObserver)
        }
    }
    
    /**
     Enables the recording of undo operations.
     
     Because undo registration is enabled by default, it is often used to balance a prior
     `disableUndoRegistration()` message. Undo registration isn’t actually re-enabled until an
     enable message balances the last disable message in effect. Raises an
     `NSInternalInconsistencyException` if invoked while no `disableUndoRegistration()`
     message is in effect.
     */
    open func enableUndoRegistration() {
        if _registrationCounter == 1 {
            _raiseException(message: "enableUndoRegistration may only be invoked with matching call to disableUndoRegistration")
        }
        _registrationCounter += 1
        if _registrationCounter == 1 {
            processRunLoopObservers(CFRunLoopAddObserver)
        }
    }
    
    private func processRunLoopObservers(_ method: (CFRunLoop?, CFRunLoopObserver?, CFRunLoopMode?) -> Void) {
        for mode in runLoopModes {
            method(CFRunLoopGetCurrent(), _cfRunLoopEntryObserver, mode._cfStringUniquingKnown)
            method(CFRunLoopGetCurrent(), _cfRunLoopExitObserver, mode._cfStringUniquingKnown)
        }
    }
    
    /**
     Closes the top-level undo group if necessary and invokes `undoNestedGroup()`.
     
     This method also invokes `endUndoGrouping()` if the nesting level is 1.
     Raises an `NSInternalInconsistencyException` if more than one undo
     group is open (that is, if the last group isn’t at the top level).
     
     This method posts an `NSUndoManagerCheckpoint`.
     */
    open func undo() {
        if groupingLevel > 1 {
            _raiseException(message: "undo was called with too many nested undo groups")
        } else if groupingLevel == 1, groupsByEvent { // Darwin Foundation does not automatically terminate undo groups if `groupsByEvent` is false
            endUndoGrouping()
        }
        undoNestedGroup()
    }
    
    /**
     Performs the operations in the last group on the redo stack, if there are any, recording them on the
     undo stack as a single group.
     
     Raises an `NSInternalInconsistencyException` if the method is
     invoked during an undo operation.
     
     This method posts an `NSUndoManagerCheckpoint` and `NSUndoManagerWillRedoChange`
     before it performs the redo operation, and it posts the `NSUndoManagerDidRedoChange` after it
     performs the redo operation.
     */
    open func redo() {
        guard !isUndoing else {
            _raiseException(message: "do not invoke this method while undoing")
        }
        _postCheckpointNotification()
        isRedoing = true
        _redo()
        isRedoing = false
        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)
    }
    
    private func _redo() {
        let nextToRedo: Any
        do {
            nextToRedo = try _redoStack.firstToRedo()
            NotificationCenter.default.post(name: .NSUndoManagerWillRedoChange, object: self)
            if let operation = nextToRedo as? _UndoOperation, operation.target != nil {
                _currentRedoingOperation = _UndoOperation()
                operation.redoBlock()
                try _undoStack.add(operation: _currentRedoingOperation!)
                _currentRedoingOperation = nil
            } else if let array = nextToRedo as? [Any] {
                beginUndoGrouping()
                for item in array {
                    guard let operation = item as? _UndoOperation, operation.target != nil else { continue }
                    _currentRedoingOperation = _UndoOperation()
                    operation.redoBlock()
                    try _undoStack.add(operation: _currentRedoingOperation!)
                    _currentRedoingOperation = nil
                }
                endUndoGrouping()
            }
        } catch {
            return
        }
    }
    
    /**
     Performs the undo operations in the last undo group (whether top-level or nested), recording the
     operations on the redo stack as a single group.
     
     Raises an `NSInternalInconsistencyException` if any undo operations have been registered
     since the last `enableUndoRegistration()` message.
     
     This method posts an `NSUndoManagerCheckpoint` and `NSUndoManagerWillUndoChange`
     before it performs the undo operation, and it posts an `NSUndoManagerDidUndoChange` after it
     performs the undo operation.
     */
    open func undoNestedGroup() {
        _postCheckpointNotification()
        NotificationCenter.default.post(name: .NSUndoManagerWillUndoChange, object: self)
        isUndoing = true
        do { try _undoLastGroup() }
        catch { _raiseException(message: "call endUndoGrouping before calling this method") }
        isUndoing = false
        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)
    }
    
    private func _undoLastGroup() throws {
        let lastToUndo: Any
        do {
            lastToUndo = try _undoStack.lastToUndo()
        } catch {
            return
        }
        if let array = lastToUndo as? [Any] {
            for item in array.reversed() {
                guard let operation = item as? _UndoOperation, operation.target != nil else { continue }
                _currentUndoingOperation = operation
                operation.block()
                _currentUndoingOperation = nil
            }
            _redoStack.add(raw: array)
        } else if lastToUndo is _UndoOperation {
            throw _UndoError.cannotUndoOpenGroup
        }
    }
    
    /**
     Clears the undo and redo stacks and re-enables the receiver.
     */
    open func removeAllActions() {
        _undoStack.clear()
        _redoStack.clear()
        _registrationCounter = 1
    }
    
    /**
     Clears the undo and redo stacks of all operations involving the specified target as the recipient of the
     undo message.
     
     Doesn’t re-enable the receiver if it’s disabled.
     
     To maintain compatibility with Darwin Foundation, the `target` parameter is marked as `Any`;
     however `UndoManager` will filter out value types.
     
     - Parameter target: The recipient of the undo messages to be removed.
     */
    open func removeAllActions(withTarget target: Any) {
        guard type(of: target) is AnyClass else { return }
        _undoStack.remove(target: target as AnyObject)
        _redoStack.remove(target: target as AnyObject)
    }
    
    @available(*, unavailable, message: "Invocation targets are not supported in swift-corelibs-foundation")
    open func prepare(withInvocationTarget target: Any) -> Any {
        NSUnsupported()
    }
    
    /**
     Sets whether the next undo or redo action is discardable.
     
     Specifies that the latest undo action may be safely discarded when a document can not be saved for
     any reason.
     
     An example might be an undo action that changes the viewable area of a document.
     
     To find out if an undo group contains only discardable actions, look for the
     _NSUndoManagerGroupIsDiscardableKey_ in the `userInfo` dictionary of
     the `NSUndoManagerWillCloseUndoGroup`.
     */
    open func setActionIsDiscardable(_ discardable: Bool) {
        if isUndoing {
            _currentUndoingOperation?.flags.isDiscardable = discardable
        } else if isRedoing {
            _currentRedoingOperation?.flags.isDiscardable = discardable
        } else {
            guard groupingLevel != 0 else {
                _raiseException(message: "must begin a group before setting undo action discardability")
            }
            _undoStack.setActionIsDiscardable(discardable)
        }
    }
    
    /**
     Sets the name of the action associated with the Undo or Redo command.
     
     If `actionName` is an empty string, the action name currently associated with the menu
     command is removed.
     */
    open func setActionName(_ actionName: String) {
        if isUndoing {
            _currentUndoingOperation?.flags.actionName = actionName
        } else if isRedoing {
            _currentRedoingOperation?.flags.actionName = actionName
        } else {
            guard groupingLevel != 0 else {
                _raiseException(message: "must begin a group before registering undo")
            }
            _undoStack.setActionName(actionName)
        }
    }
    
    /**
     Returns the complete, localized title of the Undo menu command for the action identified by
     the given name.
     
     Override this method if you want to customize the localization behavior. This method is invoked by
     `undoMenuItemTitle`.
     
     - Parameter actionName: The name of the undo action.
     - Returns: The localized title of the undo menu item.
     */
    open func undoMenuTitle(forUndoActionName actionName: String) -> String { "Undo\(actionName.isEmpty ? "" : " ")\(actionName)" }
    
    /**
     Returns the complete, localized title of the Redo menu command for the action identified by the
     given name.
     
     Override this method if you want to customize the localization behavior. This method is invoked by
     `redoMenuItemTitle`.
     
     - Parameter actionName: The name of the redo action.
     - Returns: The localized title of the redo menu item.
     */
    open func redoMenuTitle(forUndoActionName actionName: String) -> String { "Redo\(actionName.isEmpty ? "" : " ")\(actionName)" }
}

extension UndoManager {
    /**
     Registers the specified closure to implement a single undo operation that the target receives.
     
     Use` registerUndo(withTarget:handler:)` to register a closure as an undo operation
     on the undo stack. The registered closure is then executed when undo is called and the undo
     operation occurs. The target needs to be a reference type so that its state can be undone or
     redone by the undo manager.
     The following example demonstrates how you can use this method to register an undo operation
     that adds an element back into a mutable array.
     
     ```swift
     var manager = UndoManager()
     var bouquetSelection: NSMutableArray = ["lilac", "lavender"]
     func pull(flower: String) [[
         bouquetSelection.remove(flower)
         manager.registerUndo(withTarget: bouquetSelection) [[ $0.add(flower) ]]
     ]]
     pull(flower: "lilac")
     // bouquetSelection == ["lavender"]
     manager.undo()
     // bouquetSelection == ["lavender", "lilac"]
     ```
     
     To avoid retain cycles with the target, operate on the closure parameter rather than on variables
     in an outer scope that reference the same target. For example, in the code listing above, the
     closure operates on the $0 parameter rather than directly on bouquetSelection.
     
     - Parameter target: The target of the undo operation.  The undo manager maintains
     an unowned reference to the target to prevent retain cycles.
     - Parameter handler: A closure to be executed when an operation is undone.  The closure
     takes a single argument, the target of the undo operation.
     */
    public func registerUndo<TargetType>(withTarget target: TargetType, handler: @escaping (TargetType) -> Void) where TargetType : AnyObject {
        guard isUndoRegistrationEnabled else { return }
        if let operation = _currentUndoingOperation {
            operation.redoBlock = { [weak target] in
                if let target = target {
                    handler(target)
                }
            }
        } else if let operation = _currentRedoingOperation {
            operation.target = target
            operation.block = { [weak target] in
                if let target = target {
                    handler(target)
                }
            }
        } else {
            let operation = _UndoOperation()
            operation.target = target
            operation.block = { [weak target] in
                if let target = target {
                    handler(target)
                }
            }
            do {
                if groupsByEvent, groupingLevel == 0 {
                    beginUndoGrouping()
                }
                try _undoStack.add(operation: operation)
            } catch {
                _raiseException(message: "must begin a group before registering undo")
            }
            _redoStack.clear()
        }
    }
}

private extension UndoManager {
    func _raiseException(function: StaticString = #function, message: @autoclosure () -> String) -> Never {
        fatalError("\(function): \(_description) is in an invalid state, \(message())")
    }
    
    func _postCheckpointNotification() {
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: self)
    }
    
    enum _UndoError : Error {
        case cannotCloseUnopenGroup
        case cannotAddOperationToEmptyGroup
        case cannotUndoBeginMark
        case redoFailure
        case cannotUndoOpenGroup
    }
    
    class _UndoStack : NSObject {
        private var _storage = NSMutableArray()
        private var _groupingLevel = 0
        private var _limit = 0
        private var _beginMarks = [(_UndoBeginMark, Int)]()
        
        var groupingLevel: Int { _groupingLevel }
        
        var count: Int {
            return _storage.count
        }
        
        var lastFlags: _UndoFlags? { (_storage.lastObject as? _Undoable)?.flags }
        
        func markEnd() throws {
            guard _beginMarks.count > 0 else { throw _UndoError.cannotCloseUnopenGroup }
            
            let (beginMark, index) = _beginMarks.removeLast()
            let endMark = _UndoEndMark(flags: beginMark.flags, beginMarkIndex: index)
            if let lastOperation = _storage.lastObject as? _UndoOperation {
                endMark.flags.actionName = lastOperation.flags.actionName
            }
            beginMark.endMarkIndex = _storage.count
            _storage.add(endMark)
            
            _groupingLevel -= 1
            if _groupingLevel == 0 {
                _enforceLimit()
            }
        }
        
        func markBegin() {
            let newMark = _UndoBeginMark()
            _beginMarks.append((newMark, _storage.count))
            _storage.add(newMark)
            _groupingLevel += 1
        }
        
        private func _removeBottom() {
            guard (_storage.lastObject as? _UndoEndMark)?.beginMarkIndex == _storage.count - 2 else { return }
            _storage.removeLastObject()
            _storage.removeLastObject()
        }
        
        func remove(target: AnyObject) {
            for item in _storage.reversed() {
                guard target === (item as? _UndoOperation)?.target else { continue }
                _storage.remove(item)
            }
            _removeBottom()
        }
        
        func add(operation: _UndoOperation) throws {
            guard _groupingLevel != 0 else {
                throw _UndoError.cannotAddOperationToEmptyGroup
            }
            _storage.add(operation)
        }
        
        func add(raw: Any) {
            if let array = raw as? [Any] {
                array.forEach { self._storage.add($0) }
                if let endMark = array.last as? _UndoMark, !endMark.isBeginMark {
                    let lastOperation = array.last(where: { $0 is _UndoOperation })
                    endMark.flags.actionName = (lastOperation as? _UndoOperation)?.flags.actionName ?? ""
                }
            } else {
                _storage.add(raw)
            }
        }
        
        func clear() {
            _storage.removeAllObjects()
        }
        
        func lastToUndo() throws -> Any {
            if let endMark = _storage.lastObject as? _UndoEndMark {
                let array = NSArray(array: Array(_storage._storage[endMark.beginMarkIndex..<_storage.count]))
                _storage.removeObjects(in: array.allObjects)
                return array
            } else if let operation = _storage.lastObject as? _UndoOperation {
                _storage.remove(operation)
                return operation
            }
            throw _UndoError.cannotUndoBeginMark
        }
        
        func firstToRedo() throws -> Any {
            if let beginMark = _storage.firstObject as? _UndoBeginMark {
                let array = NSArray(array: Array(_storage._storage[0..<(beginMark.endMarkIndex + 1)]))
                _storage.removeObjects(in: array.allObjects)
                return array
            } else if let operation = _storage.firstObject as? _UndoOperation {
                _storage.remove(operation)
                return operation
            }
            throw _UndoError.redoFailure
        }
        
        func setActionName(_ actionName: String) {
            guard let last = _storage.lastObject else { return }
            if let end = last as? _UndoMark {
                end.flags.actionName = actionName
            } else if let end = last as? _UndoOperation {
                end.flags.actionName = actionName
            }
        }
        
        func setActionIsDiscardable(_ discardable: Bool) {
            guard let last = _storage.lastObject else { return }
            if let end = last as? _UndoMark, end.isBeginMark {
                end.flags.isDiscardable = discardable
            } else if let end = last as? _UndoOperation {
                end.flags.isDiscardable = discardable
                guard let _last = _beginMarks.last else { return }
                _beginMarks.last?.0.flags.isDiscardable = _last.0.flags.isDiscardable && discardable
            }
        }
        
        func setLimit(_ limit: Int) {
            _limit = limit
            _enforceLimit()
        }
        
        private func _enforceLimit() {
            guard _limit != 0 else { return }
            let groups = _topLevelGroups()
            guard groups.count > _limit else { return }
            let groupsToRemove = groups[0..<(groups.count - _limit)]
            let lengthOfRemoval = (groupsToRemove.last?.location ?? 0) + (groupsToRemove.last?.length ?? 0) + 1
            groups[(groups.count - _limit)..<groups.count].forEach {
                (_storage[$0.location] as? _UndoBeginMark)?.endMarkIndex -= lengthOfRemoval
                (_storage[$0.location + $0.length] as? _UndoEndMark)?.beginMarkIndex -= lengthOfRemoval
            }
            _storage = NSMutableArray(array: Array(_storage.dropFirst(lengthOfRemoval)))
        }
        
        private func _topLevelGroups() -> [NSRange] {
            var groupsRanges = [NSRange]()
            var idx = 0
            
            while idx < _storage.count {
                guard let mark = _storage[idx] as? _UndoBeginMark else {
                    assertionFailure("The next top level entry is not an `_UndoBeginMark`.  This produces an invalid stack")
                    return []
                }
                groupsRanges.append(NSRange(location: idx, length: mark.endMarkIndex - idx))
                idx = mark.endMarkIndex + 1
            }
            
            return groupsRanges
        }
        
        private class _UndoBeginMark : NSObject, _UndoMark {
            let isBeginMark = true
            let flags = _UndoMarkFlags() as _UndoFlags
            var endMarkIndex = NSNotFound
        }
        
        private class _UndoEndMark : NSObject, _UndoMark {
            let isBeginMark = false
            let flags: _UndoFlags
            var beginMarkIndex: Int
            
            init(flags: _UndoFlags, beginMarkIndex: Int) {
                self.flags = flags
                self.beginMarkIndex = beginMarkIndex
            }
        }
    }
    
    class _UndoOperation : NSObject, _Undoable {
        let flags = _UndoMarkFlags() as _UndoFlags
        
        weak var target: AnyObject?
        var block: () -> Void = { }
        var redoBlock: () -> Void = { }
    }
    
    class _UndoMarkFlags: _UndoFlags {
        var isDiscardable = false
        var actionName = ""
    }
}

public let NSUndoManagerGroupIsDiscardableKey = "NSUndoManagerGroupIsDiscardableKey"

extension NSNotification.Name {
    /**
     Posted whenever an `UndoManager` object opens or closes an undo group (except when it opens a
     top-level group) and when checking the redo stack in `canRedo`.
     
     The notification object is the `UndoManager` object. This notification does not contain a
     `userInfo` dictionary.
     */
    public static let NSUndoManagerCheckpoint: NSNotification.Name = .init(rawValue: "NSUndoManagerCheckpoint")
    
    /**
     Posted just before an NSUndoManager object performs an undo operation.
     
     If you invoke `undo()` or `undoNestedGroup()`, this notification is posted. The notification
     object is the `UndoManager` object. This notification does not contain a `userInfo` dictionary.
     */
    public static let NSUndoManagerWillUndoChange: NSNotification.Name = .init(rawValue: "NSUndoManagerWillUndoChange")
    
    /**
     Posted just before an `UndoManager` object performs a redo operation (`redo()`).
     
     The notification object is the `UndoManager` object. This notification does not contain a
     `userInfo` dictionary.
     */
    public static let NSUndoManagerWillRedoChange: NSNotification.Name = .init(rawValue: "NSUndoManagerWillRedoChange")
    
    /**
     Posted just after an `UndoManager` object performs an undo operation.
     
     If you invoke `undo()` or `undoNestedGroup()`, this notification is posted. The notification
     object is the `UndoManager` object. This notification does not contain a `userInfo` dictionary.
     */
    public static let NSUndoManagerDidUndoChange: NSNotification.Name = .init(rawValue: "NSUndoManagerDidUndoChange")
    
    /**
     Posted just after an `UndoManager` object performs a redo operation (`redo()`).
     
     The notification object is the `UndoManager` object. This notification does not contain a
     `userInfo` dictionary.
     */
    public static let NSUndoManagerDidRedoChange: NSNotification.Name = .init(rawValue: "NSUndoManagerDidRedoChange")
    
    /**
     Posted whenever an `UndoManager` object opens an undo group, which occurs in the
     implementation of the `beginUndoGrouping()` method.
     
     The notification object is the `UndoManager` object. This notification does not contain a
     `userInfo` dictionary.
     */
    public static let NSUndoManagerDidOpenUndoGroup: NSNotification.Name = .init(rawValue: "NSUndoManagerDidOpenUndoGroup")
    
    /**
     Posted before an `UndoManager` object closes an undo group, which occurs in the implementation
     of the `endUndoGrouping()` method.
     
     The notification object is the `UndoManager` object. Prior to OS X v10.7 this notification did not
     contain a `userInfo` dictionary. In macOS 10.7 and later the `userInfo` dictionary may contain
     the `NSUndoManagerGroupIsDiscardableKey` key, with a `NSNumber` boolean
     value of `YES`, if the undo group as a whole is discardable.
     */
    public static let NSUndoManagerWillCloseUndoGroup: NSNotification.Name = .init(rawValue: "NSUndoManagerWillCloseUndoGroup")
    
    /**
     Posted after an `UndoManager` object closes an undo group, which occurs in the implementation
     of the `endUndoGrouping()` method.
     
     The notification object is the `UndoManager` object. This notification does not contain a
     `userInfo` dictionary.
     */
    public static let NSUndoManagerDidCloseUndoGroup: NSNotification.Name = .init(rawValue: "NSUndoManagerDidCloseUndoGroup")
}
