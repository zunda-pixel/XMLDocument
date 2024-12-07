//
//  Copyright (c) 2019 Changbeom Ahn
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation
import libxml2XMLDocument

public enum XMLError: Error {
    case invalidStringEncoding
    case noMemory
    case libxml2
}

open class XMLDocument: XMLNode {
    open var xmlData: Data {
        return xmlString.data(using: .utf8) ?? Data()
    }
    
    private let _docPtr: xmlDocPtr?
    
    public init(data: Data, options: Int) throws {
        let encoding: String.Encoding = .utf8
        let xml = String(data: data, encoding: encoding)
        
        guard let charsetName = CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)) as String?,
            let cur = xml?.cString(using: encoding) else {
                throw XMLError.invalidStringEncoding
        }
        let url: String = ""
        let option = 0
        // FIXME: xmlParseMemory?
        _docPtr = xmlReadDoc(UnsafeRawPointer(cur).assumingMemoryBound(to: xmlChar.self), url, charsetName, CInt(option))
        
        super.init(nodePtr: nil, owner: nil)
    }
    
    deinit {
        if owner == nil, let doc = _docPtr {
            xmlFreeDoc(doc)
        }
    }
    
    public convenience init(xmlString: String, options: Int) throws {
        guard let data = xmlString.data(using: .utf8) else { fatalError() }
        
        try self.init(data: data, options: options)
    }
    
    open func rootElement() -> XMLElement? {
        let root = _docPtr.flatMap { xmlDocGetRootElement($0) }
        return root.map { XMLElement(nodePtr: $0, owner: self) }
    }
    
    override func withNodePtr<Result>(body: (xmlNodePtr?) throws -> Result) rethrows -> Result {
        guard let pointer = _docPtr else { return try body(nil) }
        return try pointer.withMemoryRebound(to: xmlNode.self, capacity: 1, body)
    }
}

open class XMLElement: XMLNode {

    class Attribute: XMLNode {
        private let pointer: xmlAttrPtr?
        
        init(pointer: xmlAttrPtr?, owner: XMLNode?) {
            self.pointer = pointer
            
            super.init(nodePtr: nil, owner: owner)
        }
        
        deinit {
            if owner == nil, let pointer = pointer {
                xmlFreeProp(pointer)
            }
        }
        
        override func withNodePtr<Result>(body: (xmlNodePtr?) throws -> Result) rethrows -> Result {
            guard let pointer = pointer else { return try body(nil) }
            return try pointer.withMemoryRebound(to: xmlNode.self, capacity: 1, body)
        }
    }
    
    public convenience init(name: String, stringValue string: String? = nil) {
        let node = xmlNewNode(nil, name)
        assert(node != nil)
        
        self.init(nodePtr: node, owner: nil)
        
        stringValue = string
    }
    
    override init(nodePtr: xmlNodePtr?, owner: XMLNode?) {
        super.init(nodePtr: nodePtr, owner: owner)
    }
    
    open func attribute(forName name: String) -> XMLNode? {
        var _attr = withNodePtr { $0?.pointee.properties }
        
        repeat {
            guard let attr = _attr else {
                break
            }

            if attr.pointee.ns != nil && attr.pointee.ns.pointee.prefix != nil {
                if xmlStrQEqual(attr.pointee.ns.pointee.prefix, attr.pointee.name, name) != 0 {
                    return Attribute(pointer: attr, owner: self)
                }
            } else {
                if xmlStrEqual(attr.pointee.name, name) != 0 {
                    return Attribute(pointer: attr, owner: self)
                }
            }
            
            _attr = attr.pointee.next
        } while _attr != nil
        
        return nil
    }
    
    open func addChild(_ child: XMLNode) {
        withNodePtr { parent in
            child.withNodePtr {
                guard let element = parent, let cur = $0 else {
                    assertionFailure()
                    return
                }
                xmlAddChild(element, cur)
                
                child.owner = self
            }
        }
    }
    
    open func addAttribute(_ attribute: XMLNode) {
        withNodePtr { parent in
            attribute.withNodePtr {
                guard let element = parent, let cur = $0 else {
                    assertionFailure()
                    return
                }
                xmlAddChild(element, cur)
                
                attribute.owner = self
            }
        }
    }
    
    fileprivate func detach(_ attribute: UnsafeMutablePointer<_xmlAttr>) {
        let parent = attribute.pointee.parent
        
        if attribute.pointee.prev == nil {
            if attribute.pointee.next == nil {
                parent?.pointee.properties = nil
            } else {
                parent?.pointee.properties = attribute.pointee.next
                attribute.pointee.next.pointee.prev = nil
            }
        } else {
            if attribute.pointee.next == nil {
                attribute.pointee.prev.pointee.next = nil
            } else {
                attribute.pointee.prev.pointee.next = attribute.pointee.next
                attribute.pointee.next.pointee.prev = attribute.pointee.prev
            }
        }
        
        attribute.pointee.parent = nil
        attribute.pointee.prev = nil
        attribute.pointee.next = nil
        attribute.pointee.ns = nil
    }
    
    open func removeAttribute(forName name: String) {
        withNodePtr {
            var pointer = $0?.pointee.properties
            while let attribute = pointer {
                if xmlStrEqual(attribute.pointee.name, name) != 0 {
                    detach(attribute)
                    return
                }
                
                pointer = attribute.pointee.next
            }
        }
    }
}

open class XMLNode {
    open class func element(withName name: String) -> Any {
        return XMLElement(name: name)
    }
    
    open class func element(withName name: String, stringValue string: String) -> Any {
        return XMLElement(name: name, stringValue: string)
    }
    
    open class func attribute(withName name: String, stringValue: String) -> Any {
        let pointer = xmlNewProp(nil, name, stringValue)
        assert(pointer != nil)
        return XMLElement.Attribute(pointer: pointer, owner: nil)
    }
    
    open class func text(withStringValue stringValue: String) -> Any {
        let pointer = xmlNewText(stringValue)
        assert(pointer != nil)
        return XMLNode(nodePtr: pointer, owner: nil)
    }
    
    open var stringValue: String? {
        get {
            return withNodePtr {
                $0.flatMap {
                    let content = xmlNodeGetContent($0)
                    defer {
                        xmlFree(content)
                    }
                    return content.flatMap { String(utf8String: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                }
            }
        }
        
        set {
            withNodePtr {
                guard let node = $0 else { fatalError() }
                let escaped = xmlEncodeSpecialChars(node.pointee.doc, newValue ?? "")
                xmlNodeSetContent(node, escaped)
                xmlFree(escaped)
            }
        }
    }
    
    open var children: [XMLNode]? {
        var children: [XMLNode] = []
        
        withNodePtr {
            var pointer = $0?.pointee.children
            while let child = pointer {
                children.append(makeNode(pointer: child))
                pointer = child.pointee.next
            }
        }
        
        return children
    }
    
    open var name: String? {
        return withNodePtr {
            return $0?.pointee.name.map { String(cString: $0) }
        }
    }
    
    open var xmlString: String {
        return withNodePtr { node in
            guard let buffer = xmlBufferCreate() else {
                return ""
            }
            defer {
                xmlBufferFree(buffer)
            }

            let count = xmlNodeDump(buffer, node?.pointee.doc, node, 0, 0)

            if count < 0 {
                return ""
            }
            return String(cString: buffer.pointee.content)
        }
    }
    
    open var parent: XMLNode? {
        return withNodePtr {
            $0?.pointee.parent.map { makeNode(pointer: $0) }
        }
    }
    
    private var _nodePtr: xmlNodePtr?
    
    var owner: XMLNode?
    
    init(nodePtr: xmlNodePtr?, owner: XMLNode?) {
        _nodePtr = nodePtr
        self.owner = owner
    }
    
    deinit {
        if owner == nil, let node = _nodePtr {
            xmlFreeNode(node)
        }
    }
    
    open func nodes(forXPath xpath: String) throws -> [XMLNode] {
        return try withNodePtr { nodePtr in
            let ctxt = nodePtr.flatMap { xmlXPathNewContext($0.pointee.doc) }
            if ctxt == nil {
                throw XMLError.noMemory
            }
            ctxt?.pointee.node = nodePtr
            
//            if let nsDictionary = namespaces {
//                for (ns, name) in nsDictionary {
//                    xmlXPathRegisterNs(ctxt, ns, name)
//                }
//            }
            
            let result = xmlXPathEvalExpression(xpath, ctxt)
            defer {
                xmlXPathFreeObject(result)
            }
            xmlXPathFreeContext(ctxt)
            
            guard let nodeSet = result?.pointee.nodesetval else {
                throw XMLError.libxml2
            }
            
            let count = Int(nodeSet.pointee.nodeNr)
            guard count > 0 else {
                return []
            }
            
            var nodes: [XMLNode] = []
            
            for index in 0..<count {
                guard let node = nodeSet.pointee.nodeTab?[index] else {
                    throw XMLError.libxml2
                }
                nodes.append(makeNode(pointer: node))
            }
            
            return nodes
        }
    }
    
    open func detach() {
        withNodePtr {
            guard let child = $0 else {
                return
            }
            
            let parent = child.pointee.parent
            
            if child.pointee.prev == nil {
                if child.pointee.next == nil {
                    parent?.pointee.children = nil
                    parent?.pointee.last = nil
                } else {
                    parent?.pointee.children = child.pointee.next
                    child.pointee.next.pointee.prev = nil
                }
            } else {
                if child.pointee.next == nil {
                    parent?.pointee.last = child.pointee.prev
                    child.pointee.prev.pointee.next = nil
                } else {
                    child.pointee.prev.pointee.next = child.pointee.next
                    child.pointee.next.pointee.prev = child.pointee.prev
                }
            }
            
            child.pointee.parent = nil
            child.pointee.prev = nil
            child.pointee.next = nil
        }
    }
    
    func withNodePtr<Result>(body: (xmlNodePtr?) throws -> Result) rethrows -> Result {
        return try body(_nodePtr)
    }
    
    func makeNode(pointer: xmlNodePtr) -> XMLNode {
        switch pointer.pointee.type {
        case XML_ELEMENT_NODE:
            return XMLElement(nodePtr: pointer, owner: self)
        // TODO: attr, ...
        default:
            return XMLNode(nodePtr: pointer, owner: self)
        }
    }
}
