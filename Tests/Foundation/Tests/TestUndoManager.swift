// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

class TestUndoManager : XCTestCase {
    static var allTests: [(String, (TestUndoManager) -> () throws -> Void)] {
        return [
            ("test_init", test_init),
            ("test_emptyGroup", test_emptyGroup),
            ("test_simpleRedo", test_simpleRedo),
            ("test_simpleUndo", test_simpleUndo),
            ("test_simpleRedoUndo", test_simpleRedoUndo),
            ("test_limitEnforcement", test_limitEnforcement),
            ("test_runLoopListening", test_runLoopListening),
            ("test_differentActionNames", test_differentActionNames),
            ("test_simpleRedoNoRegistration", test_simpleRedoNoRegistration),
            ("test_simpleRedoUndoNoRegistration", test_simpleRedoUndoNoRegistration),
            ("test_cannotUndoOpenGroup", test_cannotUndoOpenGroup),
            ("test_cannotEnableUndoRegistrationOffBalance", test_cannotEnableUndoRegistrationOffBalance),
            ("test_endUndoGroupingOffBalance", test_endUndoGroupingOffBalance),
            ("test_cannotRedoWhileUndoing", test_cannotRedoWhileUndoing),
            ("test_cannotCallUndoNestedGroupOnOpenGroup", test_cannotCallUndoNestedGroupOnOpenGroup),
            ("test_cannotSetActionDiscardableWithNoGroup", test_cannotSetActionDiscardableWithNoGroup),
            ("test_cannotSetActionNameWithNoGroup", test_cannotSetActionNameWithNoGroup),
            ("test_cannotRegisterUndoIfNoOpenGroup", test_cannotRegisterUndoIfNoOpenGroup),
        ]
    }

    // Test normal usage
    
    func test_init() {
        let undoManager = UndoManager()
        
        XCTAssertFalse(undoManager.canUndo, "An empty UndoManager cannot undo")
        XCTAssertFalse(undoManager.canRedo, "An empty UndoManager cannot redo")
        XCTAssertEqual(undoManager.groupingLevel, 0, "An empty UndoManager has no groupings yet")
        XCTAssertTrue(undoManager.groupsByEvent, "By default, an UndoManager listens to the current CFRunLoop")
    }
    
    func test_runLoopListening() {
        let undoManager = UndoManager()
        var testVar = 5
        
        let _expectation = expectation(description: "RunLoop")
        RunLoop.current.perform {
            testVar = 6
            undoManager.registerUndo(withTarget: self, handler: { _ in testVar = 4 })
            _expectation.fulfill()
        }
        wait(for: [_expectation], timeout: 10.0)
        undoManager.undo()
        XCTAssertEqual(testVar, 4, "Undo failed.")
    }
    
    func test_simpleUndo() {
        let undoManager = UndoManager()
        
        var x = 5
        undoManager.registerUndo(withTarget: self, handler: { _ in
            x = 4
        })
        undoManager.undo()
        XCTAssertEqual(x, 4, "Undo Failed")
    }
    
    func test_simpleRedo() {
        let undoManager = UndoManager()
        
        var x = 5
        undoManager.registerUndo(withTarget: self, handler: { _ in
            x = 4
            undoManager.registerUndo(withTarget: self, handler: { _ in x = 6 })
        })
        undoManager.undo()
        undoManager.redo()
        XCTAssertEqual(x, 6, "Redo Failed")
    }
    
    func test_simpleRedoNoRegistration() {
        let undoManager = UndoManager()
        
        var x = 5
        undoManager.registerUndo(withTarget: self, handler: { _ in
            x = 4
        })
        undoManager.undo()
        undoManager.redo()
        XCTAssertEqual(x, 4, "Redo Failed")
    }
    
    func test_simpleRedoUndoNoRegistration() {
        let undoManager = UndoManager()
        
        var x = 5
        undoManager.registerUndo(withTarget: self, handler: { _ in
            x = 4
            undoManager.registerUndo(withTarget: self, handler: { _ in x = 6 })
        })
        undoManager.undo()
        undoManager.redo()
        XCTAssertTrue(undoManager.canUndo,
                      "A new undo operation for the redo op was not recorded")
        undoManager.undo()
        XCTAssertEqual(x, 6, "Redo Failed")
    }
    
    func test_simpleRedoUndo() {
        let undoManager = UndoManager()
        
        var x = 5
        func registerUndoStack() {
            undoManager.registerUndo(withTarget: self) { _ in
                x = 4
                undoManager.registerUndo(withTarget: self) { _ in
                    x = 6
                    registerUndoStack()
                }
            }
        }
        registerUndoStack()
        undoManager.undo()
        undoManager.redo()
        XCTAssertTrue(undoManager.canUndo,
                      "A new undo operation for the redo op was not recorded")
        undoManager.undo()
        XCTAssertEqual(x, 4, "Redo Failed")
    }
    
    func test_emptyGroup() {
        let undoManager = UndoManager()
        undoManager.beginUndoGrouping()
        undoManager.endUndoGrouping()
        XCTAssertTrue(undoManager.canUndo, "Empty group should not get removed")
    }
    
    func test_differentActionNames() {
        let undoManager = UndoManager()
        
        var x = 5
        func registerUndoStack() {
            undoManager.registerUndo(withTarget: self) { _ in
                x = 4
                undoManager.registerUndo(withTarget: self) { _ in
                    x = 6
                    registerUndoStack()
                }
                if undoManager.isUndoing {
                    undoManager.setActionName("Set to 6")
                }
            }
            undoManager.setActionName("Set to 4")
        }
        _ = x // To silence "written but never read" warning
        registerUndoStack()
        XCTAssertEqual(undoManager.undoActionName, "Set to 4", "Bad action logic")
        undoManager.undo()
        XCTAssertEqual(undoManager.redoActionName, "Set to 6", "Bad action logic")
    }
    
    func test_limitEnforcement() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let levels = 5
        
        undoManager.levelsOfUndo = levels
        
        (0..<(levels + 1)).forEach {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self, handler: { _ in })
            undoManager.setActionName("\($0)")
            undoManager.endUndoGrouping()
        }
        (0..<levels).forEach { index in undoManager.undo() }
        XCTAssertEqual(undoManager.undoActionName, "", "A surprise top level group still exists in the undo stack!")
    }

    // Test invalid usage

    func test_cannotUndoOpenGroup() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self, handler: { _ in })
            undoManager.undo()
        }
    }

    func test_cannotEnableUndoRegistrationOffBalance() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.enableUndoRegistration()
            undoManager.enableUndoRegistration()
        }

        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.disableUndoRegistration()
            undoManager.disableUndoRegistration()
            undoManager.disableUndoRegistration()
            undoManager.disableUndoRegistration()
            undoManager.enableUndoRegistration()
            undoManager.enableUndoRegistration()
            undoManager.enableUndoRegistration()
            undoManager.enableUndoRegistration()
            undoManager.enableUndoRegistration()
        }
    }

    func test_endUndoGroupingOffBalance() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.endUndoGrouping()
        }

        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            undoManager.beginUndoGrouping()
            undoManager.endUndoGrouping()
            undoManager.endUndoGrouping()
            undoManager.endUndoGrouping()
        }
    }

    func test_cannotRedoWhileUndoing() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: undoManager, handler: { $0.redo() })
            undoManager.endUndoGrouping()
            undoManager.undo()
        }
    }

    func test_cannotCallUndoNestedGroupOnOpenGroup() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self, handler: { _ in })
            undoManager.undoNestedGroup()
        }
    }

    func test_cannotSetActionDiscardableWithNoGroup() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.setActionIsDiscardable(true)
        }
    }

    func test_cannotSetActionNameWithNoGroup() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.setActionName("Undo the void")
        }
    }

    func test_cannotRegisterUndoIfNoOpenGroup() {
        assertCrashes {
            let undoManager = UndoManager()
            undoManager.groupsByEvent = false
            undoManager.registerUndo(withTarget: self, handler: { _ in })
        }
    }
}
