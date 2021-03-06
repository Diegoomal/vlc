/*
 * HLSManager.hpp
 *****************************************************************************
 * Copyright © 2015 - VideoLAN authors
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/
#ifndef HLSMANAGER_HPP
#define HLSMANAGER_HPP

#include "../adaptative/PlaylistManager.h"
#include "../adaptative/logic/AbstractAdaptationLogic.h"
#include "playlist/M3U8.hpp"

namespace hls
{
    using namespace adaptative;

    class HLSStreamOutputFactory : public AbstractStreamOutputFactory
    {
        public:
            virtual AbstractStreamOutput *create(demux_t*, const StreamFormat &) const;
    };

    class HLSManager : public PlaylistManager
    {
        public:
            HLSManager( playlist::M3U8 *,
                        AbstractStreamOutputFactory *,
                        logic::AbstractAdaptationLogic::LogicType type,
                        stream_t *stream );
            virtual ~HLSManager();
            virtual AbstractAdaptationLogic *createLogic(AbstractAdaptationLogic::LogicType);
            virtual bool updatePlaylist();
    };

}

#endif // HLSMANAGER_HPP
