//
//  BookController.swift
//  App
//
//  Created by Jinxiansen on 2018/7/25.
//

import Foundation
import Vapor
import Fluent
import FluentPostgreSQL
import SwiftSoup

class BookController: RouteCollection {
    
    var elements : [Element]?
    var currentIndex = 0
    var typeId = 0
    var bookId = 0
    
    var amount:TimeAmount? = TimeAmount.seconds(3)
    
    func boot(router: Router) throws {
        
        let group = router.grouped("book")
        group.get("story", use: getBookLastChapterContentHandler)
        group.get("start", use: crawlerFanRenBookHandler)
        
        //test
        group.get("html", use: getHtmlDataHandler)
        
        group.get("allChapters", use: getAllChaptersHandler)
        
        group.get("chapter",Int.parameter, use: getChatperContentHandler)
        
    }
}

extension BookController {
    
    func getAllChaptersHandler(req: Request) throws -> Future<View> {
        
        let name = req.query[String.self,at:"name"] ?? ""
        
        let futureFirst = BookInfo.query(on: req).filter(\.bookName ~~ name).first()
        
        return futureFirst.flatMap({ (exist) in
                
                guard let exist = exist else {
                    return try req.view().render("leaf/allChapters")
                }
                
                let all = BookChapter.query(on: req).filter(\.bookId == exist.bookId).sort(\.chapterId,.descending).all()
                return all.flatMap({ (chapters) in
                        
                        struct ChapterContext: Content {
                            var bookName: String?
                            var chapters: [BookChapter]?
                        }
                        
                        let context = ChapterContext(bookName: exist.bookName, chapters: chapters)
                        return try req.view().render("leaf/allChapters", context)
                        
                    })
                
            })
    }
    
    func getChatperContentHandler(_ req: Request) throws -> Future<View> {
        
        let id = try req.parameters.next(Int.self)
        
        let futureFirst = BookChapter.query(on: req).filter(\.chapterId == id).first()
        
        return futureFirst.flatMap({ (chapter) in
                
                let contents = chapter?.content?.components(separatedBy: "\n\n") ?? []
                let pter = ChapterContext(bookName: chapter?.bookName,
                                          time: chapter?.updateTime,
                                          chaptName: (chapter?.chapterName ?? ""),
                                          contents: contents)
                
                return try req.view().render("leaf/chapter",pter)
            })
    }
    
    func getBookLastChapterContentHandler(_ req: Request) throws -> Future<Response> {
        let name = req.query[String.self,at:"name"] ?? ""
        
        let futureFirst = BookInfo.query(on: req).filter(\.bookName ~~ name).first()
        
        return futureFirst.flatMap({ (info) in
                guard let info = info else {
                    return try ResponseJSON<Empty>(status: .error,
                                                   message: "????????????: \(name)").encode(for: req)
                }
                
                let futureChapterFirst = BookChapter.query(on: req).filter(\.bookId == info.bookId).sort(\.chapterId,.descending).first()
                
                return futureChapterFirst.flatMap({ (chapter) in
                        
                        let contents = chapter?.content?.components(separatedBy: "\n\n") ?? []
                        let pter = ChapterContext(bookName: info.bookName,
                                                  time: chapter?.updateTime,
                                                  chaptName: "???????????????" + (chapter?.chapterName ?? ""),
                                                  contents: contents)
                        
                        return try req.view().render("leaf/chapter",pter).encode(for: req)
                    })
            })
        
    }
    
    func getHtmlDataHandler(_ req: Request) throws -> Future<String> {
        
        let client = try req.make(Client.self)
        let url = "https://www.piaotian.com/html/9/9102/"
        return client.get(url).flatMap { try $0.convertGBKString(req) }
    }
    
    func crawlerFanRenBookHandler(_ req: Request) throws -> Future<ResponseJSON<Empty>> {
        
        typeId = 9
        bookId = 9102
        let url = "https://www.piaotian.com/html/\(typeId)/\(bookId)/"
        
        return try req.client().get(url)
            .flatMap { try $0.convertGBKString(req) }
            .map({ html -> ResponseJSON<Empty> in
                debugPrint("???????????? -> \(html)\n\n")
                
                let document = try SwiftSoup.parse(html)
                let mainBody = try document.select("div[class='mainbody']")
                
                var auther = ""
                var bookName = ""
                if let first = mainBody.first() {
                    let div = try first.select("div[class='list']").text()
                    auther = div.components(separatedBy: "??????[").first?.replacingOccurrences(of: " ", with: "") ?? ""
                    bookName = div.components(separatedBy: "[").last?.components(separatedBy: "]").first ?? ""
                }
                let lis = try mainBody.select("div[class='centent']").select("a")
                
                debugPrint("\n\(bookName) \(auther) ??????????????? \(lis.array().count) \(TimeManager.current())")
                
                let revertLis = lis.reversed()
                
                self.elements = revertLis
                self.currentIndex = 0
                
                if self.elements == nil || self.elements?.count == 0 {
                    return ResponseJSON<Empty>(status: .error,
                                               message: "\(html)")
                }
                
                try self.bookExistHandler(req,
                                          revertLis: revertLis,
                                          bookName: bookName,
                                          auther: auther)
                
                func runRepeatTimer() throws {
                    
                    guard let amount = self.amount else { return }
                    _ = req.eventLoop.scheduleTask(in: amount, {
                        try runRepeatTimer()
                        try self.saveBookContentHandler(req: req,
                                                        bookName: bookName,
                                                        auther: auther,
                                                        bookId: self.bookId,
                                                        typeId: self.typeId)
                    })
                }
                try runRepeatTimer()
                
                return ResponseJSON<Empty>(status: .ok,
                                           message: "???????????? \(self.typeId)/\(self.bookId)")
            })
        
    }
    
    
    func bookExistHandler(_ req: Request,
                          revertLis: [Element],
                          bookName: String,
                          auther: String) throws {
        
        guard revertLis.count > 0 else { return }
        
        let futureFirst = BookInfo.query(on: req).filter(\.bookId == self.bookId).first()
        
        _ = futureFirst.map({ (exist) in
            
            if var exist = exist {
                exist.chapterCount = revertLis.count
                exist.updateTime = TimeManager.current()
                _ = exist.update(on: req)
                debugPrint("???????????????:\(exist.bookName ?? "") \(TimeManager.current())")
            }else {
                let bookInfo = BookInfo(id: nil,
                                        typeId: self.typeId,
                                        bookId: self.bookId,
                                        bookName: bookName,
                                        chapterCount: revertLis.count,
                                        updateTime: TimeManager.current(),
                                        content: nil,
                                        auther: auther,bookImg: nil)
                
                _ = bookInfo.save(on: req).map({ (info) in
                    debugPrint("???????????????:\(info)")
                })
            }
        })
    }
    
    // ????????????????????????
    func saveBookContentHandler(req: Request,bookName: String,
                                auther: String,
                                bookId: Int,
                                typeId: Int) throws {
        
        guard let elements = self.elements else { return }
        guard currentIndex < elements.count else { return }

        let li = elements[currentIndex]
        let address = try li.attr("href")
        let chpName = try li.text()
        let str = address.components(separatedBy: ".html").first ?? ""
        let chpId = Int(str) ?? 0
        let detailURL = "https://www.piaotian.com/html/\(typeId)/\(bookId)/\(address)"
        
        let first = BookChapter.query(on: req).filter(\.chapterId == chpId).first()
        
        _ = first.flatMap(to: Empty.self) { (exist) in
            
            //?????????????????????????????????????????????????????????
            if let exist = exist {
                debugPrint("?????????: \(exist.chapterName ?? "none") \(TimeManager.current())\n")
                self.amount = nil
                
                _ =  req.eventLoop.scheduleTask(in: TimeAmount.minutes(90), {
                    debugPrint("???????????? \(TimeManager.current())\n\n")
                    self.amount = TimeAmount.seconds(10)
                    _ = try self.crawlerFanRenBookHandler(req)
                })
                
            }else {
                _ = try self.getDetailContentHandler(req, detailURL: detailURL).map({ (content) -> EventLoopFuture<BookChapter> in
                    let book = BookChapter(id: nil,typeId: typeId,
                                           bookId: bookId,
                                           bookName: bookName,
                                           chapterId: chpId,
                                           chapterName: chpName,
                                           updateTime: TimeManager.current(),
                                           content: content,
                                           auther: auther,
                                           desc: "")
                    debugPrint("????????????\(book.chapterName ?? "") \(TimeManager.current())")
                    
                    if self.currentIndex == elements.count - 1 {
                        let em = EmailContent(email: "hi@jinxiansen.com",
                                              myName: bookName,
                                              subject: chpName,
                                              text: content)
                        _ = try EmailSender.sendEmail(req, content: em).map({ (state) in
                            _ = EmailResult(id: nil, state: state,
                                                email: em.email,
                                                sendTime: TimeManager.current())
                                .save(on: req)
                        })
                    }
                    
                    return book.save(on: req)
                })
            }
            
            if self.currentIndex < elements.count {
                self.currentIndex += 1
            }else {
                debugPrint("?????????????????????\(TimeManager.current())")
                self.amount = nil
            }
            return req.eventLoop.newSucceededFuture(result: Empty())
        }
    }
    
    //?????? detailURL ???????????????????????????
    func getDetailContentHandler(_ req: Request,detailURL: String) throws -> Future<String> {
        
        let client = try req.make(FoundationClient.self)
        
        return client.get(detailURL)
            .flatMap { try $0.convertGBKString(req) }
            .map ({ html -> String in
                let document = try SwiftSoup.parse(html)
                let content = try document.text().components(separatedBy: "???????????? ????????").last?.components(separatedBy: " ???????????? ???????????????").first?.replacingOccurrences(of: " ????????", with: "\n\n") ?? ""
                
                return content
            })
    }
    
}



private struct ChapterContext: Content {
    var bookName: String?
    var time: String?
    var chaptName: String?
    var contents: [String]
}









