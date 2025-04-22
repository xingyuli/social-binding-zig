const httpz = @import("httpz");
const Router = httpz.Router;
const Action = httpz.Action;

const App = @import("../app.zig");
const AppRouter = Router(*App, Action(*App));

const wechat = @import("wechat.zig");
const count = @import("count.zig");

pub fn create(router: *AppRouter) void {
    var g_wechat = router.group("/socialbinding/wechat", .{});
    wechat.mount(&g_wechat);

    var g_count = router.group("/socialbinding/count", .{});
    count.mount(&g_count);
}
