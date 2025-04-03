const httpz = @import("httpz");
const Router = httpz.Router;
const Action = httpz.Action;

const App = @import("../app.zig");
const AppRouter = Router(*App, Action(*App));

const wechat = @import("wechat.zig");

pub fn create(router: *AppRouter) void {
    var g = router.group("/socialbinding/wechat", .{});
    wechat.mount(&g);
}
