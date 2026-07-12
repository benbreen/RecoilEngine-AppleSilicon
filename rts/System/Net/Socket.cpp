/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

#include "Socket.h"

#include "lib/streflop/streflop_cond.h"

#include "System/Log/ILog.h"
#include "System/StringUtil.h"

#if defined(__APPLE__)
#include <cerrno> // EHOSTUNREACH (Local Network privacy detection)
#endif


namespace netcode
{

asio::io_service netservice;

bool CheckErrorCode(asio::error_code& err)
{
	// connection reset can happen when host did not start up
	// before the client wants to connect
	if (!err || err.value() == asio::error::connection_reset ||
		err.value() == asio::error::try_again) { // this should only ever happen with async sockets, but testing indicates it happens anyway...
		return false;
	} else {
		LOG_L(L_WARNING, "Network error %i: %s", err.value(),
				err.message().c_str());
		return true;
	}
}

bool CheckErrorCode(asio::error_code& err, const asio::ip::udp::endpoint& dest)
{
#if defined(__APPLE__)
	// macOS Local Network privacy: when the user denies (or never granted)
	// the Local Network permission, every UDP send to a LAN address fails
	// with EHOSTUNREACH — which looks exactly like a routing problem and
	// times out with a generic message. Explain it once, actionably.
	// (Internet servers are unaffected; only RFC1918/link-local targets.)
	if (err && err.value() == EHOSTUNREACH && dest.address().is_v4()) {
		const uint32_t a = dest.address().to_v4().to_uint();
		const bool priv = ((a >> 24) == 10) ||                    // 10/8
		                  ((a >> 20) == 0xAC1) ||                 // 172.16/12
		                  ((a >> 16) == 0xC0A8) ||                // 192.168/16
		                  ((a >> 16) == 0xA9FE);                  // 169.254/16
		static bool warned = false;
		if (priv && !warned) {
			warned = true;
			LOG_L(L_ERROR,
				"Cannot reach %s: macOS is blocking Local Network access for "
				"this app. Open System Settings > Privacy & Security > Local "
				"Network and enable Beyond All Reason, then retry. "
				"(Playing on internet servers is not affected.)",
				dest.address().to_string().c_str());
		}
	}
#endif
	return CheckErrorCode(err);
}

asio::ip::udp::endpoint ResolveAddr(const std::string& host, int port, asio::error_code* err)
{
	assert(err);
	using namespace asio;
	ip::address tempAddr = WrapIP(host, err);
	if (!*err)
		return ip::udp::endpoint(tempAddr, port);

	auto errBuf = *err; // WrapResolve() might clear err
	asio::io_service io_service;
	ip::udp::resolver resolver(io_service);
	ip::udp::resolver::query query(host, IntToString(port));
	auto iter = WrapResolve(resolver, query, err);
	ip::udp::resolver::iterator end;
	if (!*err && iter != end) {
		return *iter;
	}

	if (!*err) *err = errBuf;
	return ip::udp::endpoint(tempAddr, 0);
}


asio::ip::address WrapIP(const std::string& ip,
		asio::error_code* err)
{
	asio::ip::address addr;

	if (err == NULL) {
		addr = asio::ip::address::from_string(ip);
	} else {
		addr = asio::ip::address::from_string(ip, *err);
	}

	// (date of note: 08/05/10)
	// something in from_string() is invalidating the FPU flags
	// tested on win2k and linux (not happening there)
	streflop::streflop_init<streflop::Simple>();
	return addr;
}

asio::ip::udp::resolver::iterator WrapResolve(
		asio::ip::udp::resolver& resolver,
		asio::ip::udp::resolver::query& query,
		asio::error_code* err)
{
	asio::ip::udp::resolver::iterator resolveIt;

	if (err == NULL) {
		resolveIt = resolver.resolve(query);
	} else {
		resolveIt = resolver.resolve(query, *err);
	}

	// (date of note: 08/22/10)
	// something in resolve() is invalidating the FPU flags
	streflop::streflop_init<streflop::Simple>();
	return resolveIt;
}


asio::ip::address GetAnyAddress(const bool IPv6)
{
	if (IPv6) {
		return asio::ip::address_v6::any();
	}
	return asio::ip::address_v4::any();
}


} // namespace netcode

