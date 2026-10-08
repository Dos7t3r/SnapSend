import SwiftUI
import SnapSendCore

struct CoursesScreen: View {
    @ObservedObject var model: WorkspaceModel
    var openPhoto: (PhotoRecord) -> Void
    @State private var selectedCourse: UUID?
    @State private var sectionEditor: CourseSection?
    @State private var name = ""
    @State private var courseEditor: UUID?
    @State private var archived = false
    private var visibleCourses: [Course] { model.catalog.courses.filter { ($0.archived == true) == archived && $0.id != model.catalog.context(for: model.catalog.inboxLessonID)?.lesson.courseID } }
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack { Text("课程").font(Aurora.TypeStyle.title); Spacer(); Toggle("回收站", isOn: $archived).toggleStyle(.button).onChange(of: archived) { _, _ in selectedCourse = nil }.font(Aurora.TypeStyle.caption); Button("新建课程", systemImage: "plus") { name = ""; model.showingNewCourseAlert = true }.auroraButton(primary: true) }
            Text("课程 → 固定 Section → 按日期归档。每个 Section 只需绑定一次聊天。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Aurora.Space.gap) {
                    if selectedCourse == nil {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: Aurora.Space.gap), GridItem(.flexible(), spacing: Aurora.Space.gap)], spacing: Aurora.Space.gap) {
                            ForEach(visibleCourses) { course in
                                Button { selectedCourse = course.id } label: {
                                    VStack(alignment: .leading, spacing: Aurora.Space.gap) {
                                        Image(systemName: "folder.fill").font(Aurora.TypeStyle.number).foregroundStyle(Aurora.courseColor(model.catalog.courses.firstIndex { $0.id == course.id } ?? 0))
                                        Text(course.name).font(Aurora.TypeStyle.heading)
                                        Text("\(model.catalog.sections?.filter { $0.courseID == course.id }.count ?? 0) 个 Section · \(model.records.filter { model.catalog.context(for: $0.sessionID)?.lesson.courseID == course.id }.count) 张照片").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
                                    }.padding(Aurora.Space.card).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                                }.buttonStyle(.plain)
                            }
                        }
                    } else {
                        Button("返回全部课程", systemImage: "arrow.left") { selectedCourse = nil }.auroraButton()
                    }
                    ForEach(model.catalog.courses.filter { ($0.archived == true) == archived && $0.id == selectedCourse }) { course in
                        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
                            HStack(spacing: Aurora.Space.inset) {
                                Image(systemName: "folder.fill").foregroundStyle(Aurora.courseColor(model.catalog.courses.firstIndex { $0.id == course.id } ?? 0)).font(Aurora.TypeStyle.heading)
                                Button { selectedCourse = selectedCourse == course.id ? nil : course.id } label: { VStack(alignment: .leading, spacing: Aurora.Space.tiny) { Text(course.name).font(Aurora.TypeStyle.heading); Text("\(model.catalog.sections?.filter { $0.courseID == course.id }.count ?? 0) 个 Section · \(model.records.filter { model.catalog.context(for: $0.sessionID)?.lesson.courseID == course.id }.count) 张照片").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) } }.buttonStyle(.plain)
                                Spacer()
                                Menu {
                                    if archived { Button("恢复课程") { model.archiveCourse(course.id, archived: false) } }
                                    else {
                                        Button("编辑课程名称") { courseEditor = course.id; name = course.name }
                                        Button("添加 Section") { sectionEditor = CourseSection(courseID: course.id, name: "TUT0101") }
                                        Button("导出全部原图") { model.exportCourse(course.id) }
                                        Button("移入回收站") { model.archiveCourse(course.id, archived: true) }
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            if !archived {
                                ForEach((model.catalog.sections ?? []).filter { $0.courseID == course.id }) { section in
                                    SectionRow(model: model, section: section, color: Aurora.courseColor(model.catalog.courses.firstIndex { $0.id == course.id } ?? 0)) { sectionEditor = section }
                                    if selectedCourse == course.id {
                                        ForEach(model.catalog.lessons.filter { $0.sectionID == section.id }.reversed()) { lesson in
                                            DisclosureGroup {
                                                ForEach(model.records.filter { $0.sessionID == lesson.id }) { photo in PhotoRow(model: model, photo: photo) { openPhoto(photo) } }
                                                Button("导出这一天的照片") { model.exportLesson(lesson.id) }.buttonStyle(.borderless)
                                            } label: { Label(lesson.startedAt.formatted(date: .abbreviated, time: .shortened) + (lesson.title.isEmpty ? "" : " · " + lesson.title), systemImage: "calendar").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary) }.padding(.leading, Aurora.Space.page)
                                        }
                                    }
                                }
                            }
                        }.padding(Aurora.Space.card).glassCard()
                    }
                    if model.catalog.courses.isEmpty { EmptyPhotos() }
                }
            }
        }
        .alert("课程名称", isPresented: Binding(get: { courseEditor != nil }, set: { if !$0 { courseEditor = nil } })) {
            TextField("课程名称", text: $name); Button("取消", role: .cancel) { courseEditor = nil }; Button("保存") { if let id = courseEditor { model.renameCourseID(id, name: name) }; courseEditor = nil }
        }
        .sheet(item: $sectionEditor) { section in SectionEditor(model: model, section: section) }
    }
}
struct SectionEditor: View {
    @ObservedObject var model: WorkspaceModel
    @State var section: CourseSection
    @Environment(\.dismiss) private var dismiss
    @State private var scheduled = false
    @State private var weekday = 2
    @State private var start = 9 * 60
    @State private var end = 10 * 60
    @State private var url = ""
    private var valid: Bool { !section.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!scheduled || start < end) && (url.isEmpty || ChatURL.isConversation(url)) }
    var body: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            Text("编辑 Section").font(Aurora.TypeStyle.heading)
            TextField("名称，例如 LEC0101", text: $section.name).textFieldStyle(.roundedBorder)
            TextField("ChatGPT 对话链接（可稍后绑定）", text: $url).textFieldStyle(.roundedBorder)
            Text("支持普通聊天和项目内聊天。保存链接后，在对应页面打开扩展即可重新连接。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            Toggle("按每周课表选择目标", isOn: $scheduled)
            if scheduled {
                Picker("星期", selection: $weekday) { ForEach(1...7, id: \.self) { day in Text(["日", "一", "二", "三", "四", "五", "六"][day - 1]).tag(day) } }
                HStack { timePicker("开始", value: $start); timePicker("结束", value: $end) }
                Text("使用 Mac 本地时间；正在上课的 Section 优先于手动目标。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            }
            HStack { Button("取消") { dismiss() }.auroraButton(); Spacer(); Button("保存") { section.chatURL = url.isEmpty ? nil : url; section.schedule = scheduled ? WeeklySchedule(weekday: weekday, startMinute: start, endMinute: end) : nil; model.updateSection(section); dismiss() }.auroraButton(primary: true).disabled(!valid) }
        }.padding(Aurora.Space.page).frame(width: Aurora.Space.editor).preferredColorScheme(.dark)
            .onAppear { url = section.chatURL ?? ""; scheduled = section.schedule != nil; weekday = section.schedule?.weekday ?? 2; start = section.schedule?.startMinute ?? 540; end = section.schedule?.endMinute ?? 600 }
    }
    private func timePicker(_ title: String, value: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: value.wrappedValue / 60, minute: value.wrappedValue % 60)) ?? Date()
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
}
