import SwiftUI
import AppKit
import SnapSendCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var query = ""
    @State private var courseName = ""
    @State private var guide = false
    @State private var inspector = false
    @State private var deleteConfirmation = false
    @State private var settingsTab = "prompts"
    @State private var collapsedCourses: Set<UUID> = []
    @State private var showingTrash = false
    @State private var archiveID: UUID?
    @State private var archiveConfirmation = false
    @State private var lessonEditor: UUID?
    @State private var lessonTitle = ""
    @State private var moveSheet = false
    @State private var moveTarget: UUID?
    @AppStorage("SnapSendAppearance") private var appearance = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88) }
    private var entries: [DeliveryEntry] { model.deliveries.filter { $0.lessonID == model.selectedLesson } }
    private var needsReview: Int { entries.filter { [.uncertain, .failed].contains($0.state) }.count }
    private var activeSelection: Bool { model.selectedLesson != nil && model.selectedLesson == model.catalog.activeLessonID }

    var body: some View {
        ZStack {
            SnapBackdrop()
            HStack(spacing: 0) {
                sidebar.frame(width: 250).padding(12)
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let banner = model.alertBanner { bannerView(banner).transition(.move(edge: .top).combined(with: .opacity)) }
                    readinessPanel
                    if guide { setupPanel }
                    photoWorkspace
                }.padding(.vertical, 26).padding(.leading, 12).padding(.trailing, 26)
            }
        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .tint(SnapTheme.blue)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .animation(motion, value: model.alertBanner?.id)
        .animation(motion, value: guide)
        .animation(motion, value: inspector)
        .animation(motion, value: model.isSelectMode)
        .sheet(isPresented: $model.showingSettingsSheet) { DeliverySettingsSheet(model: model, initialTab: settingsTab).tint(SnapTheme.blue) }
        .alert("新建课程", isPresented: $model.showingNewCourseAlert) {
            TextField("课程名称，例如 STA256", text: $courseName)
            Button("取消", role: .cancel) {}
            Button("创建并开始上课") { model.createCourse(courseName); courseName = "" }
                .disabled(courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("每次上课单独按时间归档，课程可反复使用。") }
        .alert("重命名课程", isPresented: $model.showingRenameAlert) {
            TextField("课程名称", text: $courseName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.renameCourse(courseName) }
        }
        .confirmationDialog("将课程移到回收站？", isPresented: $archiveConfirmation) {
            Button("移到回收站", role: .destructive) { if let id = archiveID { model.archiveCourse(id, archived: true) } }
        } message: { Text("所有课堂和照片均保留，可随时恢复。当前课程的拍摄与自动投递会暂停。") }
        .alert("课堂名称", isPresented: Binding(get: { lessonEditor != nil }, set: { if !$0 { lessonEditor = nil } })) {
            TextField("例如：概率密度与期望", text: $lessonTitle)
            Button("取消", role: .cancel) { lessonEditor = nil }
            Button("保存") { if let id = lessonEditor { model.renameLesson(id, title: lessonTitle) }; lessonEditor = nil }
        }
        .sheet(isPresented: $moveSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Text("移动到其他课堂").font(.title2.bold())
                Text("只调整 Mac 归档，手机历史仍按拍摄时的课堂保留。移动后自动投递会暂停。").font(.callout).foregroundStyle(.secondary)
                List(selection: $moveTarget) {
                    ForEach(model.catalog.courses.filter { $0.archived != true }) { course in
                        Section(course.name) {
                            ForEach(model.catalog.lessons.filter { $0.courseID == course.id && $0.id != model.selectedLesson }) { lesson in
                                Text(lesson.title.isEmpty ? lesson.startedAt.formatted(date: .abbreviated, time: .shortened) : lesson.title).tag(lesson.id)
                            }
                        }
                    }
                }.frame(height: 260)
                HStack { Button("取消") { moveSheet = false }; Spacer(); Button("移动照片") { if let id = moveTarget { model.moveSelectedPhotos(to: id) }; moveSheet = false }.buttonStyle(.borderedProminent).disabled(moveTarget == nil) }
            }.padding(24).frame(width: 480)
        }
        .confirmationDialog("删除选中的 \(model.selectedPhotoIDs.count) 张照片？", isPresented: $deleteConfirmation) {
            Button("删除 Mac 原图", role: .destructive) { model.batchDeleteSelected() }
        } message: { Text("这会删除 Mac 中的原图及归档记录。手机上的照片会保留。") }
    }

    private var sidebar: some View {
        let counts = Dictionary(grouping: model.records, by: \.sessionID).mapValues(\.count)
        let courses = model.catalog.courses.filter { ($0.archived == true) == showingTrash }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) { SnapMark(size: 36); Text("SnapSend").font(.title3.bold()) }.padding(.top, 6)
            HStack { Image(systemName: "magnifyingglass"); TextField("搜索课程、课堂或日期", text: $query).textFieldStyle(.plain) }.font(.callout).foregroundStyle(.secondary).padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            HStack { Text(showingTrash ? "回收站" : "课程目录").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text("\(courses.count)").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(courses.reversed()) { course in
                        let lessons = model.catalog.lessons.filter { $0.courseID == course.id && (query.isEmpty || course.name.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) || $0.startedAt.formatted(date: .numeric, time: .shortened).contains(query)) }
                        if !lessons.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Button { if collapsedCourses.contains(course.id) { collapsedCourses.remove(course.id) } else { collapsedCourses.insert(course.id) } } label: {
                                    HStack(spacing: 8) { Image(systemName: collapsedCourses.contains(course.id) ? "chevron.right" : "chevron.down").font(.caption2.bold()).frame(width: 10); Image(systemName: "folder.fill").foregroundStyle(SnapTheme.blue); Text(course.name).font(.subheadline.bold()); Spacer() }.padding(.vertical, 8).padding(.horizontal, 5)
                                }.buttonStyle(.plain).padding(.trailing, 26)
                                .contextMenu { courseActions(course, lessons: lessons) }
                                .overlay(alignment: .trailing) {
                                    Menu { courseActions(course, lessons: lessons) } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                                        .menuStyle(.borderlessButton).frame(width: 24).help("管理课程：改名、导出、回收站")
                                }
                                if !collapsedCourses.contains(course.id) || !query.isEmpty {
                                    ForEach(lessons.reversed()) { lesson in
                                        Button { if !showingTrash { model.chooseLesson(lesson.id) } } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: lesson.id == model.catalog.activeLessonID ? "record.circle.fill" : "doc.text").font(.caption).foregroundStyle(lesson.id == model.catalog.activeLessonID ? SnapTheme.blue : Color.secondary)
                                                VStack(alignment: .leading, spacing: 3) { if !lesson.title.isEmpty { Text(lesson.title).font(.callout).lineLimit(1) }; Text(lesson.startedAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))).font(lesson.title.isEmpty ? .callout : .caption).foregroundStyle(lesson.title.isEmpty ? Color.primary : Color.secondary) }
                                                Spacer(minLength: 2); Text("\(counts[lesson.id, default: 0])").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            }.padding(.vertical, 9).padding(.horizontal, 10).background(model.selectedLesson == lesson.id && !showingTrash ? SnapTheme.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                        }.buttonStyle(.plain).padding(.leading, 23).overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 10) }
                                        .contextMenu {
                                            if !showingTrash {
                                                Button("编辑课堂名称") { lessonEditor = lesson.id; lessonTitle = lesson.title }
                                                Button("继续记录此课堂") { model.chooseLesson(lesson.id); model.resumeLesson() }
                                                Button("导出这节课") { model.exportLesson(lesson.id) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if courses.isEmpty { Text(showingTrash ? "回收站为空。移入这里的课程可以恢复。" : "新建课程后，每节课将作为子目录显示。").font(.callout).foregroundStyle(.secondary).padding(8) }
                }
            }
            if !showingTrash { Button { courseName = ""; model.showingNewCourseAlert = true } label: { Label("新建课程", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large) }
            Button { showingTrash.toggle() } label: { Label(showingTrash ? "返回课程" : "回收站", systemImage: showingTrash ? "arrow.left" : "trash").font(.callout) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button { model.showingSettingsSheet = true } label: { Label("设置", systemImage: "slider.horizontal.3") }.buttonStyle(.plain)
                Spacer()
                Button { guide.toggle() } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("详细使用指南")
                Menu { Button("跟随系统") { appearance = "system" }; Button("浅色") { appearance = "light" }; Button("深色") { appearance = "dark" } } label: { Image(systemName: "circle.lefthalf.filled") }.menuStyle(.borderlessButton).frame(width: 22)
            }.font(.callout).foregroundStyle(.secondary)
        }.padding(16).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func courseActions(_ course: Course, lessons: [Lesson]) -> some View {
        if showingTrash {
            Button("恢复课程") { model.archiveCourse(course.id, archived: false) }
        } else {
            Button("重命名课程") { if let first = lessons.first { model.chooseLesson(first.id) }; courseName = course.name; model.showingRenameAlert = true }
            Button("新一节课") { if let first = lessons.first { model.chooseLesson(first.id) }; model.newLesson() }
            Button("导出全部照片") { model.exportCourse(course.id) }
            Divider()
            Button("移到回收站", role: .destructive) { archiveID = course.id; archiveConfirmation = true }
        }
    }

    private var readinessPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.usbConnected && model.activeContext != nil ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(model.usbConnected && model.activeContext != nil ? Color.green : SnapTheme.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.activeContext == nil ? "尚未开课，先开始一节课" : !model.usbConnected ? "可以离线拍照，尚未同步到 Mac" : "可以拍照 · 当前记录到 \(model.activeContext?.courseName ?? "")").font(.headline)
                    Text(model.activeContext == nil ? "历史照片仍可查看、移动和导出。" : !model.usbConnected ? model.connectionStatus + "。手机需已保存当前课堂，确认数据线、解锁手机并打开 App。" : "手机确认拍照后，原图会通过 USB 自动保存。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.activeContext == nil, model.selectedContext != nil { Button("开始这节课") { model.resumeLesson() }.buttonStyle(.borderedProminent) }
                else if !model.usbConnected { Button("连接手机") { model.connect() }.buttonStyle(.bordered) }
            }
            Divider()
            HStack {
                Label(model.autoSend && (model.deliveryTarget != "chrome" || model.browserConnected && model.chatMatchesClass && model.browserPageStatus.isEmpty) ? "AI 自动发送已开启" : model.autoSend ? "AI 发送暂时等待" : "AI 自动发送未开启", systemImage: "paperplane").font(.subheadline.weight(.medium))
                Spacer()
                if model.deliveryTarget == "chrome" && model.chatMatchesClass && model.browserConnected { Button("显示绑定聊天") { model.requestBrowserFocus() }.buttonStyle(.bordered).controlSize(.small) }
                Button(model.chatMatchesClass ? "投递设置" : "配置 AI") { settingsTab = "ai"; model.showingSettingsSheet = true }.buttonStyle(.bordered).controlSize(.small)
            }
            Text(model.deliveryTarget == "native" ? "原生投递会短暂激活 AI 窗口；发送未确认时暂停，请核对。" : !model.chatMatchesClass ? "照片仍会保存。需要自动发送时，在 Chrome 本节课的聊天中点击扩展绑定。" : !model.browserConnected ? "浏览器尚未连接，打开 Chrome 中的 SnapSend 扩展重新检查。照片仍会保存。" : !model.browserPageStatus.isEmpty ? model.browserPageStatus + "。可点“显示绑定聊天”检查页面；未确认发送的照片需先在 Mac 核对。" : model.autoSend ? "后台发送，无需切换焦点；草稿或 AI 正在回答时会等待。" : "已绑定，发送处于暂停状态。请在照片区点击开启。").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.selectedContext?.courseName ?? "课堂工作台").font(.system(size: 26, weight: .bold))
                HStack(spacing: 8) {
                    if activeSelection { Label("正在上课", systemImage: "record.circle.fill").foregroundStyle(SnapTheme.blue) }
                    Text(model.selectedContext?.lesson.startedAt.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))) ?? "从一门课程，开始记录").foregroundStyle(.secondary)
                }.font(.callout)
            }
            Spacer()
            if model.selectedContext != nil {
                Button { model.newLesson() } label: { Label("新一节课", systemImage: "plus") }.buttonStyle(.borderedProminent)
                Menu {
                    Button("继续记录此课堂") { model.resumeLesson() }
                    Button("重命名课程") { courseName = model.selectedContext?.courseName ?? ""; model.showingRenameAlert = true }
                    Button("发送下课总结") { model.sendClassSummaryPromptNow() }.disabled(!activeSelection)
                    Button("复制总结提示词") { model.copySummaryPrompt() }
                    Divider()
                    Button("结束当前课堂") { model.finishLesson() }.disabled(model.activeContext == nil)
                } label: { Image(systemName: "ellipsis").padding(12) }.menuStyle(.borderlessButton).fixedSize().modifier(SnapGlass())
            }
        }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Label("上课前，准备这三步", systemImage: "sparkles").font(.headline); Spacer(); if model.usbConnected && model.chatMatchesClass { Button("收起") { guide = false }.buttonStyle(.plain) } }
            HStack(alignment: .top, spacing: 18) {
                setupStep("1", title: "连接 iPhone", detail: model.usbConnected ? "USB 已连接，照片会先保存到 Mac" : "插上数据线，解锁手机并打开 SnapSend", done: model.usbConnected) {
                    Button(model.usbConnected ? "已连接" : "连接手机") { model.connect() }.disabled(model.usbConnected)
                }
                setupStep("2", title: "开始课堂", detail: model.activeContext?.courseName ?? "新建课程，或在目录选择课程开始新一节课", done: model.activeContext != nil) {
                    Button("新建课程") { courseName = ""; model.showingNewCourseAlert = true }
                }
                setupStep("3", title: "绑定 AI 聊天", detail: model.chatMatchesClass ? "本节课已绑定聊天，可随时暂停投递" : "安装桥接，在 Chrome 专用聊天点击扩展绑定", done: model.chatMatchesClass) {
                    Button(model.chatMatchesClass ? "投递设置" : "安装与绑定") { settingsTab = "ai"; model.showingSettingsSheet = true }
                }
            }
            if model.pairingRequired {
                HStack { Text("首次配对：输入手机显示的 6 位码").font(.callout); TextField("6 位验证码", text: $model.pairingCode).frame(width: 130); Button("验证") { model.submitPairing() } }
            }
        }.padding(20).modifier(SnapSurface())
    }

    private func setupStep<Action: View>(_ number: String, title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(done ? "✓" : number).font(.callout.bold()).frame(width: 28, height: 28).foregroundStyle(done ? Color.white : SnapTheme.blue).background(done ? AnyShapeStyle(SnapTheme.gradient) : AnyShapeStyle(SnapTheme.blue.opacity(0.12)), in: Circle())
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.subheadline.bold()); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); action().buttonStyle(.bordered).controlSize(.small) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var photoWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("课堂照片", systemImage: "square.grid.2x2").font(.headline)
                Text("\(model.lessonPhotos.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if model.isSelectMode { Button("移动照片") { moveTarget = nil; moveSheet = true }.disabled(model.selectedPhotoIDs.isEmpty) }
                Spacer()
                Label(model.usbConnected ? "手机已连接" : "等待 USB", systemImage: "cable.connector").foregroundStyle(model.usbConnected ? SnapTheme.blue : Color.secondary)
                Button { model.toggleSelectMode() } label: { Image(systemName: model.isSelectMode ? "checkmark.circle.fill" : "checklist") }.help("批量选择")
                Menu { Button("导入照片") { model.importPhoto() }; Button("打开照片目录") { model.showArchive() }; Button("复制开课提示词") { model.copyClassPrompt() } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                Button { inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("照片详情")
            }.font(.caption).buttonStyle(.borderless)
            HStack {
                Image(systemName: needsReview > 0 ? "exclamationmark.circle.fill" : "paperplane.fill").foregroundStyle(needsReview > 0 ? Color.orange : SnapTheme.blue)
                Text(model.selectedContext == nil ? "尚未开课 · 创建课程后可绑定 AI" : !activeSelection ? "历史课堂 · 继续记录后可绑定 AI" : needsReview > 0 ? "\(needsReview) 张照片需要核对" : model.autoSend ? "后台自动发送已开启" : model.chatMatchesClass ? "自动发送已暂停" : "照片会保存在 Mac，绑定聊天后可发送").font(.callout)
                Spacer()
                Text("已发送 \(entries.filter { $0.state == .sent }.count) · 排队 \(entries.filter { $0.state == .queued }.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button(model.autoSend ? "暂停" : "开启") { model.autoSend ? model.pauseDelivery() : model.enableDelivery() }.buttonStyle(.bordered).controlSize(.small).disabled(!model.chatMatchesClass || !activeSelection)
            }.padding(12).background(SnapTheme.blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    if model.lessonPhotos.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "camera.viewfinder").font(.system(size: 52, weight: .light)).foregroundStyle(SnapTheme.gradient)
                            Text(model.selectedContext == nil ? "新建课程，开始记录" : activeSelection ? "这节课还没有照片" : "这节历史课堂没有照片").font(.title3.bold())
                            Text(model.selectedContext == nil ? "每门课程下按每次上课时间归档。" : activeSelection ? "拍摄条件请看上方状态。手机确认拍照后，通过 USB 同步到这里。" : "可导入照片，或点“开始这节课”继续记录。")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 370)
                            if model.selectedContext == nil { Button("新建第一门课程") { model.showingNewCourseAlert = true }.buttonStyle(SnapPrimaryButton()) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                                ForEach(model.lessonPhotos.reversed()) { photo in
                                    PhotoGridCard(photo: photo, imageURL: model.imageURL(photo), isSelected: model.selected == photo.id, isSelectMode: model.isSelectMode, isChecked: model.selectedPhotoIDs.contains(photo.id), stage: model.stageOf(photo), onSelect: {
                                        if model.isSelectMode { model.togglePhotoSelection(photo.id) } else { model.selected = photo.id; inspector = true }
                                    }, onSendToAI: { model.sendSinglePhotoToAI(photo) })
                                    .contextMenu {
                                        Button("发送给 AI") { model.sendSinglePhotoToAI(photo) }
                                        Button("复制图片") { model.selected = photo.id; model.copyImage() }
                                        Button("删除照片", role: .destructive) { model.selectedPhotoIDs = [photo.id]; deleteConfirmation = true }
                                    }
                                }
                            }.padding(4).padding(.bottom, model.isSelectMode ? 80 : 8)
                        }
                    }
                    if inspector, let photo = model.current, photo.sessionID == model.selectedLesson, let url = model.imageURL(photo) {
                        PhotoInspectorPanel(model: model, photo: photo, url: url, onClose: { inspector = false }).frame(width: 300).padding(.leading, 16).transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if model.isSelectMode {
                    FloatingCapsuleBar(selectedCount: model.selectedPhotoIDs.count, totalCount: model.lessonPhotos.count, onSelectAll: { model.selectAllPhotos() }, onDeselectAll: { model.deselectAllPhotos() }, onSendToAI: { model.batchSendSelectedToAI() }, onExport: { model.batchExportSelected() }, onDelete: { deleteConfirmation = true }, onClose: { model.toggleSelectMode() }).padding(10).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }.frame(maxHeight: .infinity)
        }.padding(16).modifier(SnapSurface(radius: 14)).frame(maxHeight: .infinity)
    }

    private func bannerView(_ banner: AppAlertBanner) -> some View {
        HStack(spacing: 12) {
            Image(systemName: banner.style.icon).foregroundStyle(banner.style.color)
            VStack(alignment: .leading, spacing: 3) { Text(banner.title).font(.subheadline.bold()); Text(banner.message).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let title = banner.actionTitle { Button(title) { model.performBannerAction() } }
            Button { model.dismissAlert() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
        }.padding(14).modifier(SnapSurface(radius: 16))
    }
}
